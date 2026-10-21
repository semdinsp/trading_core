defmodule TradingCore.Signals.VsCloses do
  @moduledoc """
  A live price measured against its own recent daily closes: the
  percentage away from their mean (`"pct"`) or the z-score against them
  (`"zscore"`). Also the realized volatility of those closes
  (`"realized_vol"`), a daily Wilder ATR (`"atr"`, `"atr_pct"`), both of
  which ignore the live price, and a daily RSI (`"rsi"`) that takes the
  live price as today's provisional close. Backs trading_signal's
  `vix_vs_closes` and `vs_closes`
  source types (e.g. `ibkr_vix_vs_5d_avg_pct`,
  `massive_qqq_vs_20d_zscore`), and lets trading_backtest replay them.

  Pure. The caller loads the daily closes (trading_signal from
  `regime_sessions` or Polygon daily bars); this module only selects the
  ones that count and does the arithmetic.

  ## No look-ahead

  The baseline for a session uses only closes from US/Eastern dates
  strictly before that session's date, so today's own (still forming)
  bar never counts. `series/5` computes each tick against the baseline
  for that tick's own date.

  ## Realized volatility

  `"realized_vol"` is close-to-close realized vol over the last `days`
  daily **returns**, so it reads `days + 1` closes (`closes_needed/2`):

      RV = sqrt(Σ r² / N) × sqrt(252) × 100,   r = ln(c_t / c_{t-1})

  Annualized and in percent, so it reads in VIX's units (e.g. 14.2).

  It is the **zero-mean** RMS of the returns, not the n − 1 sample
  standard deviation. That is the usual realized-vol convention, and at a
  short window it matters: demeaning a 5-day window that trended removes
  the trend from the volatility, understating it. It is fixed for a
  session (prior closes only), so every tick of the day gets the same
  value.

  ## Daily ATR

  `"atr"` is Wilder's ATR over prior sessions' daily bars (`:high`,
  `:low`, `:close`; selected with `bars_before/4`), in price units;
  `"atr_pct"` divides it by the last prior close, × 100, so it compares
  across symbols. `days` is the period. Every true range uses the
  previous bar's close, and Wilder smoothing needs a seed, so it reads
  `10 × days + 1` bars (`closes_needed/2`): the seed is the mean of the
  first `days` true ranges and is then smoothed over `9 × days` more, by
  which point its weight, `((days − 1) / days)^(9 × days)`, is below
  `1e-4` for any period of 3 or more (`1.6e-4` at 14). Fixed for the
  session, like `"realized_vol"`.

  ## Daily RSI

  `"rsi"` is Wilder's RSI over prior sessions' closes **plus the live
  price as today's provisional close** (the Connors RSI(2) usage: read it
  near the close and buy below 10). `days` is the period. `baseline/3`
  smooths the average gain and loss through the last prior close, seeded
  with the mean of the first `days` changes over `10 × days + 1` closes
  (`closes_needed/2`; the same convergence as the ATR). `compute/3` then
  applies one more Wilder step for the live price, so today's bar counts
  only through that provisional close. 0–100; 100 when there has been no
  loss, 50 when there has been neither gain nor loss.

  ## Arithmetic and precision

  Mean and standard deviation are computed in floats, exactly as
  trading_signal computed them before this module existed, so moving the
  live rows here changes no value. Results are rounded to 8 decimal
  places through `Decimal.from_float/1`, the same discipline as
  `TradingCore.Signals.self_zscore/5`; a baseline holds only plain
  floats, so nothing unbounded is kept in state.
  """

  @type output :: String.t()
  @type baseline ::
          %{
            required(:mean) => float(),
            required(:n) => pos_integer(),
            optional(:sd) => float()
          }
          | %{required(:rv) => float(), required(:n) => pos_integer()}
          | %{
              required(:atr) => float(),
              required(:close) => float(),
              required(:n) => pos_integer()
            }
          | %{
              required(:avg_gain) => float(),
              required(:avg_loss) => float(),
              required(:last_close) => float(),
              required(:period) => pos_integer()
            }

  @timezone "America/New_York"
  @precision 8
  @default_max_staleness_days 5
  @min_zscore_samples 3
  @trading_days_per_year 252

  @wilder_seed_multiple 10
  @bar_outputs ~w(atr atr_pct)

  @doc """
  How many daily closes (bars, for `"atr"`/`"atr_pct"`) `output` needs
  for a `days` setting:

    * `"realized_vol"`: `days + 1` (`days` counts returns);
    * `"rsi"`, `"atr"`, `"atr_pct"`: `10 × days + 1` (`days` is the
      period; the extra history lets Wilder's seed decay, see the
      moduledoc);
    * otherwise `days`.

  Pass it to `closes_before/4` (or `bars_before/4`); `series/5` does.
  """
  @spec closes_needed(pos_integer(), output()) :: pos_integer()
  def closes_needed(days, "realized_vol"), do: days + 1

  def closes_needed(days, output) when output in ["rsi" | @bar_outputs],
    do: @wilder_seed_multiple * days + 1

  def closes_needed(days, _output), do: days

  @doc """
  The last `days` daily closes from US/Eastern dates strictly before
  `today`, newest first, as Decimals.

  `daily_bars` are maps with `:timestamp` (Unix ms or a `DateTime`) and
  `:close` (number or Decimal), in any order; bars without a usable
  timestamp or close are ignored. Returns `nil` when fewer than `days`
  remain, or when the newest is more than `opts[:max_staleness_days]`
  (default #{@default_max_staleness_days}) calendar days before `today`.
  """
  @spec closes_before([map()], Date.t(), pos_integer(), keyword()) :: [Decimal.t()] | nil
  def closes_before(daily_bars, %Date{} = today, days, opts \\ []) when days > 0 do
    daily_bars
    |> Enum.flat_map(fn bar ->
      case to_decimal(Map.get(bar, :close)) do
        {:ok, close} -> [Map.put(bar, :close_decimal, close)]
        :error -> []
      end
    end)
    |> select_before(today, days, opts, & &1.close_decimal)
  end

  # The last `days` of `bars` (already filtered to usable values) from
  # US/Eastern dates strictly before `today`, newest first, mapped through
  # `pick`; nil when too few remain or the newest is stale.
  defp select_before(bars, today, days, opts, pick) do
    max_staleness = Keyword.get(opts, :max_staleness_days, @default_max_staleness_days)

    bars
    |> Enum.flat_map(fn bar ->
      with {:ok, date} <- bar_date(bar),
           :lt <- Date.compare(date, today) do
        [{date, pick.(bar)}]
      else
        _ -> []
      end
    end)
    |> Enum.sort_by(&elem(&1, 0), {:desc, Date})
    |> Enum.take(days)
    |> case do
      [{newest, _} | _] = rows when length(rows) == days ->
        if Date.diff(today, newest) <= max_staleness,
          do: Enum.map(rows, &elem(&1, 1)),
          else: nil

      _too_few ->
        nil
    end
  end

  @doc """
  The last `days` daily bars from US/Eastern dates strictly before
  `today`, newest first, as `%{high:, low:, close:}` Decimals, for the
  `"atr"` outputs. The same selection, staleness and `nil` rules as
  `closes_before/4`; a bar also needs a usable `:high` and `:low`.
  """
  @spec bars_before([map()], Date.t(), pos_integer(), keyword()) :: [map()] | nil
  def bars_before(daily_bars, %Date{} = today, days, opts \\ []) when days > 0 do
    daily_bars
    |> Enum.flat_map(fn bar ->
      with {:ok, high} <- to_decimal(Map.get(bar, :high)),
           {:ok, low} <- to_decimal(Map.get(bar, :low)),
           {:ok, close} <- to_decimal(Map.get(bar, :close)) do
        [Map.put(bar, :ohlc, %{high: high, low: low, close: close})]
      else
        _ -> []
      end
    end)
    |> select_before(today, days, opts, & &1.ohlc)
  end

  @doc """
  The baseline of `closes` (newest first, as `closes_before/4` returns
  them) for `output`: `%{mean, n}` for `"pct"`, plus the sample standard
  deviation `sd` (n − 1) for `"zscore"`. `nil` for no closes, or for
  `"zscore"` with fewer than #{@min_zscore_samples}.

  For `"realized_vol"`, `%{rv, n}` with `n` the number of returns (see
  "Realized volatility" above); `nil` for fewer than 2 closes or any
  close `<= 0`.
  """
  @spec baseline([Decimal.t() | number()] | nil, output()) :: baseline() | nil
  def baseline(nil, _output), do: nil
  def baseline([], _output), do: nil

  def baseline(_closes, output) when output in ["rsi" | @bar_outputs],
    do: raise(ArgumentError, "#{output} needs its period: use baseline/3")

  def baseline(closes, "realized_vol") do
    floats = closes |> Enum.map(&to_float/1) |> Enum.reverse()

    if length(floats) < 2 or Enum.any?(floats, &(&1 <= 0)) do
      nil
    else
      returns =
        floats
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [prev, curr] -> :math.log(curr / prev) end)

      n = length(returns)
      rms = :math.sqrt(Enum.sum(Enum.map(returns, &(&1 * &1))) / n)
      %{rv: rms * :math.sqrt(@trading_days_per_year) * 100, n: n}
    end
  end

  def baseline(closes, output) do
    floats = Enum.map(closes, &to_float/1)
    n = length(floats)
    mean = Enum.sum(floats) / n

    case output do
      "zscore" when n >= @min_zscore_samples ->
        var = Enum.sum(Enum.map(floats, &((&1 - mean) ** 2))) / (n - 1)
        %{mean: mean, sd: :math.sqrt(var), n: n}

      "zscore" ->
        nil

      _pct ->
        %{mean: mean, n: n}
    end
  end

  @doc """
  `baseline/2` with the `days` setting, which `"rsi"`, `"atr"` and
  `"atr_pct"` need as their period; other outputs ignore it.

    * `"rsi"` (closes, newest first): `%{avg_gain, avg_loss, last_close,
      period}`, Wilder-smoothed through the last prior close; `nil` with
      fewer than `days + 1` closes.
    * `"atr"`/`"atr_pct"` (bars from `bars_before/4`, newest first):
      `%{atr, close, n}`; `nil` with fewer than `days + 1` bars.
  """
  @spec baseline([term()] | nil, output(), pos_integer()) :: baseline() | nil
  def baseline(nil, _output, _days), do: nil

  def baseline(closes, "rsi", period) do
    floats = closes |> Enum.map(&to_float/1) |> Enum.reverse()

    if length(floats) < period + 1 do
      nil
    else
      changes = floats |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> b - a end)
      {seed, rest} = Enum.split(changes, period)
      seed_gain = seed |> Enum.map(&max(&1, 0.0)) |> Enum.sum() |> Kernel./(period)
      seed_loss = seed |> Enum.map(&max(-&1, 0.0)) |> Enum.sum() |> Kernel./(period)

      {avg_gain, avg_loss} =
        Enum.reduce(rest, {seed_gain, seed_loss}, fn change, {g, l} ->
          rsi_step(g, l, change, period)
        end)

      %{avg_gain: avg_gain, avg_loss: avg_loss, last_close: List.last(floats), period: period}
    end
  end

  def baseline(bars, output, period) when output in @bar_outputs do
    bars = Enum.reverse(bars)

    if length(bars) < period + 1 do
      nil
    else
      trs =
        bars
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [prev, bar] ->
          {h, l, pc} = {to_float(bar.high), to_float(bar.low), to_float(prev.close)}
          Enum.max([h - l, abs(h - pc), abs(l - pc)])
        end)

      {seed, rest} = Enum.split(trs, period)

      atr =
        Enum.reduce(rest, Enum.sum(seed) / period, fn tr, prev ->
          (prev * (period - 1) + tr) / period
        end)

      %{atr: atr, close: to_float(List.last(bars).close), n: length(trs)}
    end
  end

  def baseline(closes, output, _days), do: baseline(closes, output)

  defp rsi_step(avg_gain, avg_loss, change, period) do
    {(avg_gain * (period - 1) + max(change, 0.0)) / period,
     (avg_loss * (period - 1) + max(-change, 0.0)) / period}
  end

  defp rsi(avg_gain, avg_loss) when avg_loss == 0 and avg_gain == 0, do: 50.0
  defp rsi(_avg_gain, avg_loss) when avg_loss == 0, do: 100.0
  defp rsi(avg_gain, avg_loss), do: 100 - 100 / (1 + avg_gain / avg_loss)

  @doc """
  `price` against `baseline`, rounded to #{@precision} places:

    * `"pct"`: `(price / mean − 1) × 100`; `nil` when `mean <= 0`.
    * `"zscore"`: `(price − mean) / sd`; `nil` when the closes are flat,
      `sd <= max(|mean| × 1e-6, 1e-12)`.

    * `"realized_vol"`: the baseline's `rv`. The price is ignored, so
      every tick of a session returns the same value.
    * `"atr"`: the baseline's `atr`; `"atr_pct"`: `atr / close × 100`
      (`nil` when that close `<= 0`). The price is ignored.
    * `"rsi"`: one more Wilder step with `price` as today's provisional
      close, then `100 − 100 / (1 + avg_gain / avg_loss)`.

  `nil` for a `nil` or non-numeric price (except `"realized_vol"`) or a
  `nil` baseline.
  """
  @spec compute(Decimal.t() | number() | nil, baseline() | nil, output()) :: Decimal.t() | nil
  def compute(_price, nil, _output), do: nil
  def compute(_price, %{rv: rv}, "realized_vol"), do: round_out(rv)
  def compute(_price, %{atr: atr}, "atr"), do: round_out(atr)

  def compute(_price, %{atr: atr, close: close}, "atr_pct") when close > 0,
    do: round_out(atr / close * 100)

  def compute(_price, %{atr: _}, "atr_pct"), do: nil

  def compute(price, %{avg_gain: g, avg_loss: l, last_close: last, period: period}, "rsi") do
    case to_float(price) do
      nil ->
        nil

      value ->
        {g, l} = rsi_step(g, l, value - last, period)
        round_out(rsi(g, l))
    end
  end

  def compute(price, baseline, output) do
    case to_float(price) do
      nil -> nil
      value -> do_compute(value, baseline, output)
    end
  end

  defp do_compute(value, %{mean: mean, sd: sd}, "zscore") do
    if sd > max(abs(mean) * 1.0e-6, 1.0e-12),
      do: round_out((value - mean) / sd),
      else: nil
  end

  # Any output other than "zscore" is treated as "pct", as in trading_signal.
  defp do_compute(value, %{mean: mean}, _pct) when mean > 0,
    do: round_out((value / mean - 1) * 100)

  defp do_compute(_value, _baseline, _output), do: nil

  @doc """
  Batch form for replay: one value per tick in `ticks` (`[{DateTime.t(),
  price}]`), each computed against the baseline of the
  `closes_needed(days, output)` closes strictly before that tick's own
  US/Eastern date (no look-ahead).
  Returns `[{at, value | nil}]` in the ticks' order; baselines are built
  once per date. Same options as `closes_before/4`.
  """
  @spec series([{DateTime.t(), term()}], [map()], pos_integer(), output(), keyword()) ::
          [{DateTime.t(), Decimal.t() | nil}]
  def series(ticks, daily_bars, days, output, opts \\ []) do
    needed = closes_needed(days, output)

    {values, _cache} =
      Enum.map_reduce(ticks, %{}, fn {at, price}, cache ->
        date = et_date(at)

        {base, cache} =
          case Map.fetch(cache, date) do
            {:ok, base} ->
              {base, cache}

            :error ->
              base =
                if output in @bar_outputs,
                  do: daily_bars |> bars_before(date, needed, opts) |> baseline(output, days),
                  else: daily_bars |> closes_before(date, needed, opts) |> baseline(output, days)

              {base, Map.put(cache, date, base)}
          end

        {{at, compute(price, base, output)}, cache}
      end)

    values
  end

  ## ---------------------------------------------------------------------

  defp bar_date(%{timestamp: %DateTime{} = at}), do: {:ok, et_date(at)}

  defp bar_date(%{timestamp: ms}) when is_integer(ms) do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, at} -> {:ok, et_date(at)}
      _ -> :error
    end
  end

  defp bar_date(_bar), do: :error

  defp et_date(at), do: at |> DateTime.shift_zone!(@timezone) |> DateTime.to_date()

  defp round_out(x), do: x |> Decimal.from_float() |> TradingCore.Decimals.round(@precision)

  defp to_decimal(%Decimal{} = d), do: {:ok, d}
  defp to_decimal(x) when is_float(x), do: {:ok, Decimal.from_float(x)}
  defp to_decimal(x) when is_integer(x), do: {:ok, Decimal.new(x)}
  defp to_decimal(_x), do: :error

  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(x) when is_float(x), do: x
  defp to_float(x) when is_integer(x), do: x * 1.0
  defp to_float(_x), do: nil
end
