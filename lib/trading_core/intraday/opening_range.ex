defmodule TradingCore.Intraday.OpeningRange do
  @moduledoc """
  The opening range of a US-equities regular session, for
  opening-range-breakout (ORB) signals.

  Pure: the caller (trading_signal) supplies 1-minute bars (see
  `TradingCore.Intraday.RegularSession` for the bar shape) and, live, a
  last price. Replay and live therefore compute the same range.

  ## The range

  For a range of `minutes`, the bars used are `session_date`'s
  regular-session bars whose start falls in `[open, open + minutes)`:
  `open` is the first of those bars' open, `close` the last one's close,
  `high`/`low` the max/min over them, and `direction` is
  `sign(close − open)`, the direction of the first candle. A range longer
  than the session (say 400 minutes, or 240 on a 13:00 half day) is cut
  at the session's close.

  ## When is the range complete?

  `from_bars/4` returns `{:error, :incomplete}` until the range has
  ended. It has ended when any of these holds:

  1. the bar for the range's **last minute** (`open + minutes − 1`)
     exists;
  2. any bar in `bars` starts at or after `open + minutes` (a later
     bar proves the range's minutes have passed, even if a minute
     inside it had no trades); or
  3. `opts[:now]` (a `DateTime`) is at or after `open + minutes`.

  If the range has ended but none of its minutes traded, the result is
  `{:error, :no_bars}`. `session_date` on a weekend or holiday is
  `{:error, :no_session}`.

  ## Precision

  Prices are returned as the `Decimal` form of the bar values (floats
  via `Decimal.from_float/1`'s shortest representation). Nothing here
  divides, so no rounding is needed.
  """

  alias TradingCore.Intraday.RegularSession
  alias TradingCore.Regime.Decimals

  @type range :: %{
          high: Decimal.t(),
          low: Decimal.t(),
          open: Decimal.t(),
          close: Decimal.t(),
          direction: -1 | 0 | 1
        }

  @doc "The opening range of `session_date` over its first `minutes`. See the moduledoc."
  @spec from_bars(Enumerable.t(), Date.t(), pos_integer(), keyword()) ::
          {:ok, range()} | {:error, :incomplete | :no_session | :no_bars}
  def from_bars(bars, session_date, minutes, opts \\ [])
      when is_integer(minutes) and minutes > 0 do
    with {:ok, open_at, _close} <- session(session_date),
         {:ok, session_bars} <- RegularSession.bars_for(bars, session_date) do
      last_minute = min(minutes, RegularSession.length_minutes(session_date)) - 1
      range_end = DateTime.add(open_at, (last_minute + 1) * 60, :second)
      in_range = Enum.filter(session_bars, &(&1.minute <= last_minute))

      cond do
        not ended?(bars, in_range, last_minute, range_end, opts) -> {:error, :incomplete}
        in_range == [] -> {:error, :no_bars}
        true -> {:ok, summarize(in_range)}
      end
    end
  end

  @doc """
  Where `last` sits against a range: `1` above `high`, `-1` below `low`,
  `0` at either edge or between them. An unparseable price or range is
  `0` (no breakout).
  """
  @spec position(term(), %{high: term(), low: term()}) :: -1 | 0 | 1
  def position(last, %{high: high, low: low}) do
    with {:ok, last} <- Decimals.parse(last),
         {:ok, high} <- Decimals.parse(high),
         {:ok, low} <- Decimals.parse(low) do
      cond do
        Decimal.compare(last, high) == :gt -> 1
        Decimal.compare(last, low) == :lt -> -1
        true -> 0
      end
    else
      :error -> 0
    end
  end

  def position(_last, _range), do: 0

  ## ---------------------------------------------------------------------

  defp session(date) do
    case RegularSession.bounds(date) do
      {:ok, open, close} -> {:ok, open, close}
      :error -> {:error, :no_session}
    end
  end

  defp ended?(bars, in_range, last_minute, range_end, opts) do
    Enum.any?(in_range, &(&1.minute == last_minute)) or
      Enum.any?(bars, fn bar ->
        case RegularSession.start_time(bar) do
          {:ok, start} -> DateTime.compare(start, range_end) != :lt
          :error -> false
        end
      end) or
      now_past?(Keyword.get(opts, :now), range_end)
  end

  defp now_past?(%DateTime{} = now, range_end), do: DateTime.compare(now, range_end) != :lt
  defp now_past?(_now, _range_end), do: false

  defp summarize([first | _] = bars) do
    last = List.last(bars)

    %{
      open: first.open,
      close: last.close,
      high: bars |> Enum.map(& &1.high) |> Enum.max(Decimal),
      low: bars |> Enum.map(& &1.low) |> Enum.min(Decimal),
      direction: sign(Decimal.compare(last.close, first.open))
    }
  end

  defp sign(:gt), do: 1
  defp sign(:lt), do: -1
  defp sign(:eq), do: 0
end
