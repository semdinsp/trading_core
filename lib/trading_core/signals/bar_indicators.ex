defmodule TradingCore.Signals.BarIndicators do
  @moduledoc """
  Clocked OHLC bars built from ticks, and Wilder's ATR and ADX stepped one
  bar at a time. Backs the `:atr` and `:adx` kinds in
  `TradingCore.Signal.Compute`.

  Pure and float-based: the state holds only floats and integers, and
  callers round what they emit (`Compute` returns `Decimal`s rounded to 8
  places).

  ## Bars

  A tick at `at` belongs to bucket `floor(unix_ms(at) / interval_ms)`. A
  bar closes when the first tick of a later bucket arrives, so its values
  are final: open is the first tick of its interval, high and low the
  extremes, close the last. An interval with no tick makes no bar (no
  carry-forward fill, so an overnight gap is not a run of flat bars). A
  late tick (an earlier bucket) counts toward the open bar.

  ## Wilder smoothing

  Both indicators seed with the simple mean of their first `period`
  inputs, then apply `x̄ = (x̄_prev × (period − 1) + x) / period`, the
  same convention as `TradingCore.Volatility.atr/2`.

    * **ATR**: true range is `max(high − low, |high − prev_close|,
      |low − prev_close|)`; the first bar has no previous close, so its
      true range is `high − low` (as in `Volatility.atr/2`, so the two
      agree bar for bar). Ready after `period` bars.
    * **ADX**: from the second bar on, `+DM = high − prev_high` when that
      up-move is positive and larger than the down-move
      `prev_low − low`, else 0 (and `−DM` the mirror). `+DM`, `−DM` and
      true range are Wilder-smoothed; `±DI = 100 × smoothed ±DM /
      smoothed TR`; `DX = 100 × |+DI − −DI| / (+DI + −DI)`; ADX is DX
      Wilder-smoothed over `period` again. The DIs are ready after
      `period + 1` bars, ADX after `2 × period`. Averaging rather than
      summing the first `period` values (Wilder's original sums them)
      scales the smoothed DM and TR alike, so the DIs, DX and ADX are
      identical. A bar range of zero gives DI 0 and DX 0 rather than a
      division by zero.
  """

  @type bar :: %{open: float(), high: float(), low: float(), close: float(), start_ms: integer()}

  ## ---------------------------------------------------------------------
  ## Clocked OHLC bars
  ## ---------------------------------------------------------------------

  @doc "An empty bar builder."
  @spec bars_new() :: map()
  def bars_new, do: %{bucket: nil, bar: nil}

  @doc """
  Adds a tick. Returns `{builder, closed_bar}`, where `closed_bar` is the
  bar this tick closed (it opened a later bucket), or `nil`.
  """
  @spec bars_push(map(), DateTime.t(), float(), pos_integer()) :: {map(), bar() | nil}
  def bars_push(%{bucket: nil}, at, value, interval_ms) do
    {%{bucket: bucket_of(at, interval_ms), bar: open_bar(value)}, nil}
  end

  def bars_push(%{bucket: open, bar: bar} = builder, at, value, interval_ms) do
    bucket = bucket_of(at, interval_ms)

    if bucket > open do
      {%{bucket: bucket, bar: open_bar(value)}, Map.put(bar, :start_ms, open * interval_ms)}
    else
      {%{builder | bar: extend_bar(bar, value)}, nil}
    end
  end

  defp bucket_of(at, interval_ms),
    do: Integer.floor_div(DateTime.to_unix(at, :millisecond), interval_ms)

  defp open_bar(v), do: %{open: v, high: v, low: v, close: v}

  defp extend_bar(bar, v), do: %{bar | high: max(bar.high, v), low: min(bar.low, v), close: v}

  ## ---------------------------------------------------------------------
  ## Wilder smoothing
  ## ---------------------------------------------------------------------

  # A Wilder average: the mean of the first `period` inputs, then
  # (prev × (period − 1) + x) / period. `value` is nil until seeded.
  defp wilder_new, do: %{n: 0, sum: 0.0, value: nil}

  defp wilder_push(%{value: nil, n: n, sum: sum}, x, period) do
    n = n + 1
    sum = sum + x
    %{n: n, sum: sum, value: if(n == period, do: sum / period)}
  end

  defp wilder_push(%{value: prev} = w, x, period),
    do: %{w | n: w.n + 1, value: (prev * (period - 1) + x) / period}

  defp true_range(bar, nil), do: bar.high - bar.low

  defp true_range(bar, prev_close) do
    Enum.max([bar.high - bar.low, abs(bar.high - prev_close), abs(bar.low - prev_close)])
  end

  ## ---------------------------------------------------------------------
  ## ATR
  ## ---------------------------------------------------------------------

  @doc "An empty ATR state."
  @spec atr_new() :: map()
  def atr_new, do: %{tr: wilder_new(), prev_close: nil, close: nil}

  @doc "Folds a closed bar into the ATR state."
  @spec atr_push(map(), bar(), pos_integer()) :: map()
  def atr_push(state, bar, period) do
    tr = true_range(bar, state.prev_close)
    %{tr: wilder_push(state.tr, tr, period), prev_close: bar.close, close: bar.close}
  end

  @doc "The ATR in price units, or `nil` before `period` bars."
  @spec atr_value(map()) :: float() | nil
  def atr_value(%{tr: %{value: value}}), do: value

  @doc "ATR as a percentage of the last bar's close, or `nil`."
  @spec atr_pct_value(map()) :: float() | nil
  def atr_pct_value(%{tr: %{value: nil}}), do: nil
  def atr_pct_value(%{close: close}) when close <= 0, do: nil
  def atr_pct_value(%{tr: %{value: atr}, close: close}), do: atr / close * 100

  ## ---------------------------------------------------------------------
  ## ADX
  ## ---------------------------------------------------------------------

  @doc "An empty ADX state."
  @spec adx_new() :: map()
  def adx_new do
    %{
      prev: nil,
      tr: wilder_new(),
      plus_dm: wilder_new(),
      minus_dm: wilder_new(),
      dx: wilder_new()
    }
  end

  @doc "Folds a closed bar into the ADX state."
  @spec adx_push(map(), bar(), pos_integer()) :: map()
  def adx_push(%{prev: nil} = state, bar, _period), do: %{state | prev: bar}

  def adx_push(%{prev: prev} = state, bar, period) do
    up = bar.high - prev.high
    down = prev.low - bar.low
    plus_dm = if up > down and up > 0, do: up, else: 0.0
    minus_dm = if down > up and down > 0, do: down, else: 0.0

    state = %{
      state
      | prev: bar,
        tr: wilder_push(state.tr, true_range(bar, prev.close), period),
        plus_dm: wilder_push(state.plus_dm, plus_dm, period),
        minus_dm: wilder_push(state.minus_dm, minus_dm, period)
    }

    case di(state) do
      nil -> state
      {plus_di, minus_di} -> %{state | dx: wilder_push(state.dx, dx(plus_di, minus_di), period)}
    end
  end

  @doc "`{+DI, −DI}` on a 0–100 scale, or `nil` before `period + 1` bars."
  @spec di(map()) :: {float(), float()} | nil
  def di(%{tr: %{value: nil}}), do: nil
  def di(%{tr: %{value: tr}}) when tr == 0, do: {0.0, 0.0}

  def di(%{tr: %{value: tr}, plus_dm: %{value: p}, minus_dm: %{value: m}}),
    do: {100 * p / tr, 100 * m / tr}

  @doc "ADX on a 0–100 scale, or `nil` before `2 × period` bars."
  @spec adx_value(map()) :: float() | nil
  def adx_value(%{dx: %{value: value}}), do: value

  defp dx(plus_di, minus_di) when plus_di + minus_di == 0, do: 0.0
  defp dx(plus_di, minus_di), do: 100 * abs(plus_di - minus_di) / (plus_di + minus_di)
end
