defmodule TradingCore.Intraday.NoiseBand do
  @moduledoc """
  The intraday "noise area" of Zarattini, Aziz & Barbon, for
  noise-band breakout signals on US equities.

  Pure: the caller (trading_signal) supplies 1-minute bars (see
  `TradingCore.Intraday.RegularSession` for the bar shape) and a live
  last price, so replay and live compute the same band.

  ## Width

  For minute-of-day `m` (minutes since the 09:30 ET open; the bar
  starting at 09:30 + m):

      width(m) = mean over the previous L sessions of |close_at_m / session_open − 1|

  - **Sessions used:** the most recent `L` (`opts[:lookback]`, default
    14) regular sessions strictly before `today` that cover minute `m`.
    A session covers `m` when `m` is inside its regular hours and it has
    bars both at-or-before and at-or-after `m`. A half day has no late
    minutes, so for those minutes it is skipped, not counted as zero. So
    is a session the data only partly covers. Fewer than `L` covering
    sessions is `{:error, :insufficient_history}`.
  - **close_at_m:** the close of the bar for minute `m`. If no trade
    printed in minute `m` (no bar), the close of that session's last
    earlier bar is carried forward.
  - **session_open:** the open of the session's first regular-session
    bar, normally the 09:30 bar.

  `history_bars` may span more than `L` sessions and include extended
  hours; both are filtered out. Bars on or after `today` are ignored.

  ## Ratio

  See `ratio/5`. A ratio above `+1` means `last` is above the upper band
  and below `−1` means it is below the lower band.

  ## Precision

  Width and ratio are rounded to #{8} decimal places, so a caller can keep
  them in long-lived state (see `TradingCore.Signals`' moduledoc on
  unrounded Decimals).
  """

  alias TradingCore.Intraday.RegularSession
  alias TradingCore.Regime.Decimals

  @precision 8
  @default_lookback 14

  @doc "The noise-band width for `minute` on `today`. See the moduledoc."
  @spec width(Enumerable.t(), Date.t(), non_neg_integer(), keyword()) ::
          {:ok, Decimal.t()} | {:error, :insufficient_history}
  def width(history_bars, %Date{} = today, minute, opts \\ [])
      when is_integer(minute) and minute >= 0 do
    lookback = Keyword.get(opts, :lookback, @default_lookback)

    moves =
      history_bars
      |> Enum.group_by(&bar_date/1)
      |> Enum.filter(fn {date, _bars} -> date != :error and Date.compare(date, today) == :lt end)
      |> Enum.sort_by(fn {date, _bars} -> date end, {:desc, Date})
      |> Stream.flat_map(fn {date, bars} -> List.wrap(move_at(bars, date, minute)) end)
      |> Enum.take(lookback)

    if is_integer(lookback) and lookback > 0 and length(moves) == lookback do
      mean =
        moves
        |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
        |> Decimal.div(lookback)
        |> Decimal.round(@precision)

      {:ok, mean}
    else
      {:error, :insufficient_history}
    end
  end

  @doc """
  Where `last` sits against the noise band, as a signed multiple of
  `width`. `ratio > 1` ⇔ `last` is above the upper band and
  `ratio < −1` ⇔ below the lower band.

  With `gap_adjusted: true` (the default, the paper's variant), the band
  is anchored on both reference prices: `hi = max(today_open,
  prior_close)`, `lo = min(today_open, prior_close)`, upper `= hi × (1 +
  width)`, lower `= lo × (1 − width)`, and

      last ≥ hi -> (last / hi − 1) / width
      last ≤ lo -> (last / lo − 1) / width     (negative)
      otherwise -> 0                            (inside the gap)

  With `gap_adjusted: false` it is `(last / today_open − 1) / width` and
  `prior_close` is ignored (it may be `nil`).

  `nil` when `width` isn't positive or a required price is missing,
  unparseable or not positive.
  """
  @spec ratio(term(), term(), term(), term(), keyword()) :: Decimal.t() | nil
  def ratio(last, today_open, prior_close, width, opts \\ []) do
    with {:ok, last} <- Decimals.parse(last, :pos, []),
         {:ok, today_open} <- Decimals.parse(today_open, :pos, []),
         {:ok, width} <- Decimals.parse(width, :pos, []),
         {:ok, value} <- band_ratio(last, today_open, prior_close, width, opts) do
      Decimal.round(value, @precision)
    else
      :error -> nil
    end
  end

  @doc """
  Minutes since `session_date`'s 09:30 ET open, or `nil` outside that
  session (or on a day with no session). See
  `TradingCore.Intraday.RegularSession.minute_of_day/2`.
  """
  @spec minute_of_day(DateTime.t(), Date.t()) :: non_neg_integer() | nil
  defdelegate minute_of_day(at, session_date), to: RegularSession

  ## ---------------------------------------------------------------------

  defp bar_date(bar) do
    case RegularSession.local_date(bar) do
      {:ok, date} -> date
      :error -> :error
    end
  end

  # |close_at_m / session_open − 1| for one session, or nil when the
  # session doesn't cover minute m.
  defp move_at(bars, date, minute) do
    with length when is_integer(length) and minute < length <-
           RegularSession.length_minutes(date),
         {:ok, [first | _] = session_bars} <- RegularSession.bars_for(bars, date),
         true <- Enum.any?(session_bars, &(&1.minute >= minute)),
         %{close: close} <- session_bars |> Enum.filter(&(&1.minute <= minute)) |> List.last() do
      close |> Decimal.div(first.open) |> Decimal.sub(1) |> Decimal.abs()
    else
      _ -> nil
    end
  end

  defp band_ratio(last, today_open, prior_close, width, opts) do
    if Keyword.get(opts, :gap_adjusted, true) do
      with {:ok, prior_close} <- Decimals.parse(prior_close, :pos, []) do
        hi = Decimal.max(today_open, prior_close)
        lo = Decimal.min(today_open, prior_close)

        cond do
          Decimal.compare(last, hi) != :lt -> {:ok, scaled(last, hi, width)}
          Decimal.compare(last, lo) != :gt -> {:ok, scaled(last, lo, width)}
          true -> {:ok, Decimal.new(0)}
        end
      end
    else
      {:ok, scaled(last, today_open, width)}
    end
  end

  # (last / reference − 1) / width
  defp scaled(last, reference, width) do
    last |> Decimal.div(reference) |> Decimal.sub(1) |> Decimal.div(width)
  end
end
