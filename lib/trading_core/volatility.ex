defmodule TradingCore.Volatility do
  @moduledoc """
  Volatility measures over bars already in hand — pure, no I/O.

  Two measures, deliberately kept apart because they differ in size and a
  stop multiple calibrated on one is wrong on the other:

    * `ewma_daily_vol/2` — the close-to-close measure the live apps use.
      It reproduces `TradingHub.Volatility.Calculator.trailing_ewma_vol_sync/4`
      (the figure `TradingCore.PositionSizing.resolve_volatility_target_with_estimate/4`
      returns and the live apps cache), so a backtest calibrating
      `"volatility_multiple"` stops (see `TradingCore.RiskControls`) sees
      the same number a live entry will be given.
    * `atr/2` — Wilder's Average True Range, in price units. Includes
      gaps and intraday range, so it typically runs well above
      `ewma_daily_vol × price`. Provided for analysis; the live stop path
      does not use it.
  """

  @default_lambda 0.94
  @default_lookback_days 14
  @default_atr_period 14

  @typedoc "A bar needs at least `:ts` (DateTime or Date) and `:close`; `atr/2` also reads `:high`/`:low`."
  @type bar :: %{required(:ts) => DateTime.t() | Date.t(), required(:close) => number_like()}
  @type number_like :: Decimal.t() | number() | String.t()

  @doc """
  Trailing EWMA daily volatility — a fraction (e.g. `0.0123` for 1.23%),
  not annualized — matching the hub's `trailing_ewma_vol_sync/4`:

    1. Collapse `bars` to one close per UTC calendar day (the last bar of
       each day), so intraday bars work too. The hub reads Polygon daily
       bars, keyed by UTC day.
    2. Keep the days from `as_of − lookback_days` through `as_of`, both
       inclusive — the hub's `Polygon.Window.bounds/2` range. `:as_of`
       defaults to the latest day in `bars`; days after it are dropped.
       `:lookback_days` defaults to `14`, the hub's default `"14d"`
       window: **calendar** days, so about 10 trading days and 9 returns,
       not 14.
    3. Take `|ln(close_t / close_t-1)|` for each consecutive day.
    4. RiskMetrics EWMA: weight the most recent return's square by
       `lambda^0`, the next by `lambda^1`, …; divide by the weight total
       and take the square root. `:lambda` defaults to `0.94`.

  `bars` should end at the decision point: pass only what a live entry
  would have known. Returns `{:ok, Decimal.t()}`, or `:insufficient_data`
  with fewer than two days (no return) in the window.

  Options: `:lookback_days`, `:lambda`, `:as_of` (`Date.t()`).
  """
  @spec ewma_daily_vol([bar()], keyword()) :: {:ok, Decimal.t()} | :insufficient_data
  def ewma_daily_vol(bars, opts \\ []) when is_list(bars) do
    lookback_days = Keyword.get(opts, :lookback_days, @default_lookback_days)
    lambda = Keyword.get(opts, :lambda, @default_lambda)

    daily_closes = daily_closes(bars)

    case Keyword.get(opts, :as_of) || latest_day(daily_closes) do
      nil ->
        :insufficient_data

      as_of ->
        cutoff = Date.add(as_of, -lookback_days)

        closes =
          daily_closes
          |> Enum.filter(fn {day, _close} ->
            Date.compare(day, cutoff) != :lt and Date.compare(day, as_of) != :gt
          end)
          |> Enum.map(&elem(&1, 1))

        case abs_log_returns(closes) do
          [] -> :insufficient_data
          returns -> {:ok, returns |> ewma_vol(lambda) |> Decimal.from_float()}
        end
    end
  end

  @doc """
  The EWMA step on its own: `returns` oldest first (floats), most recent
  weighted `lambda^0`. Same arithmetic as the hub's
  `trailing_ewma_vol/2`. Raises on an empty list.
  """
  @spec ewma_vol([float()], float()) :: float()
  def ewma_vol([_ | _] = returns, lambda \\ @default_lambda) do
    {weighted_sum, weight_total} =
      returns
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.reduce({0.0, 0.0}, fn {r, i}, {sum, total} ->
        w = :math.pow(lambda, i)
        {sum + w * r * r, total + w}
      end)

    :math.sqrt(weighted_sum / weight_total)
  end

  @doc """
  Wilder's Average True Range over `bars` (oldest first), in price units.

  True range is `max(high − low, |high − prev_close|, |low − prev_close|)`;
  the first bar has no previous close, so its true range is `high − low`.
  The first ATR is the simple mean of the first `period` true ranges, then
  each later bar applies `ATR = (ATR_prev × (period − 1) + TR) / period`.

  Returns `{:ok, Decimal.t()}` for the last bar, or `:insufficient_data`
  with fewer than `period` bars. `period` defaults to `14`.
  """
  @spec atr([map()], pos_integer()) :: {:ok, Decimal.t()} | :insufficient_data
  def atr(bars, period \\ @default_atr_period) when is_list(bars) and period > 0 do
    if length(bars) < period do
      :insufficient_data
    else
      trs = true_ranges(bars)
      {seed, rest} = Enum.split(trs, period)
      first = seed |> Enum.reduce(Decimal.new(0), &Decimal.add/2) |> Decimal.div(period)

      atr =
        Enum.reduce(rest, first, fn tr, prev ->
          prev |> Decimal.mult(period - 1) |> Decimal.add(tr) |> Decimal.div(period)
        end)

      {:ok, atr}
    end
  end

  defp true_ranges([first | _] = bars) do
    first_tr = Decimal.sub(dec(first.high), dec(first.low))

    rest =
      bars
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [prev, bar] ->
        high = dec(bar.high)
        low = dec(bar.low)
        prev_close = dec(prev.close)

        Enum.max(
          [
            Decimal.sub(high, low),
            Decimal.abs(Decimal.sub(high, prev_close)),
            Decimal.abs(Decimal.sub(low, prev_close))
          ],
          Decimal
        )
      end)

    [first_tr | rest]
  end

  defp latest_day([]), do: nil
  defp latest_day(daily_closes), do: daily_closes |> List.last() |> elem(0)

  # Last close per UTC calendar day, days ascending.
  defp daily_closes(bars) do
    bars
    |> Enum.sort_by(&sort_key(&1.ts))
    |> Enum.reduce(%{}, fn bar, acc -> Map.put(acc, utc_day(bar.ts), to_float(bar.close)) end)
    |> Enum.sort_by(&elem(&1, 0), Date)
  end

  defp abs_log_returns(closes) do
    closes
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [prev, curr] -> abs(:math.log(curr / prev)) end)
  end

  defp sort_key(%DateTime{} = ts), do: DateTime.to_unix(ts, :microsecond)
  defp sort_key(%Date{} = d), do: Date.to_gregorian_days(d) * 86_400_000_000

  defp utc_day(%DateTime{} = ts), do: ts |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_date()
  defp utc_day(%Date{} = d), do: d

  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(n) when is_number(n), do: n / 1
  defp to_float(s) when is_binary(s), do: s |> Decimal.new() |> Decimal.to_float()

  defp dec(%Decimal{} = d), do: d
  defp dec(n) when is_integer(n), do: Decimal.new(n)
  defp dec(n) when is_float(n), do: Decimal.from_float(n)
  defp dec(s) when is_binary(s), do: Decimal.new(s)
end
