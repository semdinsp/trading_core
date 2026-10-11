defmodule TradingCore.Signals.VsCloses do
  @moduledoc """
  A live price measured against its own recent daily closes: the
  percentage away from their mean (`"pct"`) or the z-score against them
  (`"zscore"`). Backs trading_signal's `vix_vs_closes` and `vs_closes`
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

  ## Arithmetic and precision

  Mean and standard deviation are computed in floats, exactly as
  trading_signal computed them before this module existed, so moving the
  live rows here changes no value. Results are rounded to 8 decimal
  places through `Decimal.from_float/1`, the same discipline as
  `TradingCore.Signals.self_zscore/5`; a baseline holds only plain
  floats, so nothing unbounded is kept in state.
  """

  @type output :: String.t()
  @type baseline :: %{
          required(:mean) => float(),
          required(:n) => pos_integer(),
          optional(:sd) => float()
        }

  @timezone "America/New_York"
  @precision 8
  @default_max_staleness_days 5
  @min_zscore_samples 3

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
    max_staleness = Keyword.get(opts, :max_staleness_days, @default_max_staleness_days)

    daily_bars
    |> Enum.flat_map(fn bar ->
      with {:ok, date} <- bar_date(bar),
           {:ok, close} <- to_decimal(Map.get(bar, :close)),
           :lt <- Date.compare(date, today) do
        [{date, close}]
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
  The baseline of `closes` for `output`: `%{mean, n}` for `"pct"`, plus
  the sample standard deviation `sd` (n − 1) for `"zscore"`. `nil` for no
  closes, or for `"zscore"` with fewer than #{@min_zscore_samples}.
  """
  @spec baseline([Decimal.t() | number()] | nil, output()) :: baseline() | nil
  def baseline(nil, _output), do: nil
  def baseline([], _output), do: nil

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
  `price` against `baseline`, rounded to #{@precision} places:

    * `"pct"`: `(price / mean − 1) × 100`; `nil` when `mean <= 0`.
    * `"zscore"`: `(price − mean) / sd`; `nil` when the closes are flat,
      `sd <= max(|mean| × 1e-6, 1e-12)`.

  `nil` for a `nil` or non-numeric price or a `nil` baseline.
  """
  @spec compute(Decimal.t() | number() | nil, baseline() | nil, output()) :: Decimal.t() | nil
  def compute(_price, nil, _output), do: nil

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
  price}]`), each computed against the baseline of the `days` closes
  strictly before that tick's own US/Eastern date (no look-ahead).
  Returns `[{at, value | nil}]` in the ticks' order; baselines are built
  once per date. Same options as `closes_before/4`.
  """
  @spec series([{DateTime.t(), term()}], [map()], pos_integer(), output(), keyword()) ::
          [{DateTime.t(), Decimal.t() | nil}]
  def series(ticks, daily_bars, days, output, opts \\ []) do
    {values, _cache} =
      Enum.map_reduce(ticks, %{}, fn {at, price}, cache ->
        date = et_date(at)

        {base, cache} =
          case Map.fetch(cache, date) do
            {:ok, base} ->
              {base, cache}

            :error ->
              base = daily_bars |> closes_before(date, days, opts) |> baseline(output)
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

  defp round_out(x), do: x |> Decimal.from_float() |> Decimal.round(@precision)

  defp to_decimal(%Decimal{} = d), do: {:ok, d}
  defp to_decimal(x) when is_float(x), do: {:ok, Decimal.from_float(x)}
  defp to_decimal(x) when is_integer(x), do: {:ok, Decimal.new(x)}
  defp to_decimal(_x), do: :error

  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(x) when is_float(x), do: x
  defp to_float(x) when is_integer(x), do: x * 1.0
  defp to_float(_x), do: nil
end
