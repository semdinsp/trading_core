defmodule TradingCore.Signals do
  @moduledoc """
  Pure state-transition math for every signal kind `trading_signal` runs
  live (`TradingSignal.Signals.Derivative`/`Vwap`/`SelfZscore`/`Deviation`/
  `Wavelet`/`Regime`/`Donchian`/`Momentum`/`DefinitionSignal`'s plain
  momentum path) — extracted the same way `TradingCore.RuleEngine`,
  `TradingCore.RiskControls`, and `TradingCore.PositionSizing` were already
  extracted from `trading_system` (see each of those modules' own
  moduledocs for the established pattern this one follows).

  In `trading_signal` today, every one of these signals is a stateful
  GenServer holding a rolling window in process memory, fed by live
  `Phoenix.PubSub` ticks, calling `DateTime.utc_now()` and `Repo.get!/2`
  directly — nothing about that state or those ticks is ever persisted.
  This module pulls just the arithmetic core out of each one: given prior
  state and one new sample (plus, where relevant, an explicit `now`), what
  is the new state and the value (if any) that should be emitted? No
  GenServer, no `Phoenix.PubSub`, no `Repo`, and critically **no
  `DateTime.utc_now()` calls of its own** — every function that needs "the
  current time" takes it as an explicit `now` parameter instead.

  ## Why `now` must be a parameter, not read internally

  This is what makes it possible to *replay* a signal's exact math against
  historical data later (the motivating reason for this extraction — a
  future backtest engine needs to feed historical timestamps through the
  same windowing/trimming logic that live ticks go through today). A
  function that called `DateTime.utc_now()` itself could only ever compute
  "as of right now," which is useless for replaying what a signal would
  have computed at some point last month. Every trim/window function here
  takes `now` explicitly for exactly this reason.

  ## Live `trading_signal` GenServers call these unchanged

  `trading_signal`'s own signal modules are refactored (a separate,
  behavior-preserving pass — see this extraction's own plan) to call these
  functions instead of inlining the math: `handle_tick/2` becomes a thin
  wrapper that pulls state, calls the pure function here with
  `DateTime.utc_now()` supplied as `now`, stores the returned new state,
  and emits `{:value, v, state}` or `{:tick, state}` based on whether a
  value came back. The live signal's own test suite (already exercising
  `init_compute/1`/`handle_tick/2` end to end, including via real PubSub)
  is what proves that refactor didn't change observable behavior — nothing
  in *this* module's own tests needs to reach into `trading_signal` at
  all, since every function here is plain data in, plain data out.

  ## Rounding/precision discipline is load-bearing — relocated unchanged

  Every function below preserves its source module's exact rounding
  behavior, including *where* rounding happens (into a stored history
  entry vs. only on the emitted value) — this is not a style preference,
  it's incident history. `Decimal.div/2` and `Decimal.sub/2` are
  exact-precision operations: neither the dividend/divisor's own precision
  nor an "ordinary-looking" subtraction bounds the result's digit count.
  Left unrounded, a single such value sitting in a rolling window gets
  re-read by `Decimal.to_float/1` (or re-diffed via `Decimal.sub/2`) on
  every subsequent tick for as long as it stays in the window — confirmed
  live, more than once, as multi-hundred-thousand-message mailbox
  backlogs and 9-50MB+ per-process memory blowups (see
  `TradingSignal.Signals.Vwap`'s, `Derivative`'s, and `Deviation`'s own
  moduledocs for the specific confirmed incidents). Rounding only the
  *emitted* value would still leave every *stored* sample free to carry
  whatever precision its own tick's arithmetic happened to produce, which
  is precisely what caused those incidents — so every function here
  rounds a value before it enters history/a Welford accumulator, not just
  when it's finally returned to the caller.

  ## What's deliberately NOT extracted here

  `TradingSignal.Signals.CumulativeVolume`'s session-reset-at-9:30am-ET
  logic and its two-feed-shape message parsing (`data.volume` vs.
  `data.cumulative_volume`, IBKR vs. Massive/Polygon) stay in
  `trading_signal` — that's about live message format and session
  bookkeeping, not backtest-relevant math, and a bars-based backtest
  wouldn't reconstruct volume the same tick-diffing way live ticks do
  anyway. Only the VWAP arithmetic itself (`vwap/2`,
  `fold_price_weighted_delta/3`) is extracted here; a caller (live or
  backtest) supplies `cum_pv`/`cum_volume` however it tracks them.

  `TradingSignal.Signals.DefinitionSignal`'s `expression`-kind dispatch
  (parsing/evaluating a user-authored formula via
  `TradingSignal.Signals.Expression`) also stays in `trading_signal` — only
  its `params`-driven fallback path (a plain windowed momentum over raw
  price ticks, identical in shape to `TradingSignal.Signals.Momentum`'s
  own logic) is pure "compute a value from a window of samples" math, and
  that shape is what `momentum/4` below covers for both callers.
  """

  alias TradingCore.WelfordAcc
  alias TradingCore.WaveletTransform

  @type sample :: Decimal.t() | float() | integer() | String.t()
  @type history_entry :: {DateTime.t(), Decimal.t()}
  @type history :: [history_entry()]

  # Same value/reasoning used by every wrapping signal kind in
  # trading_signal (Derivative, Vwap, SelfZscore, Deviation, Donchian,
  # Momentum, DefinitionSignal) — generous headroom past any real price's
  # meaningful precision, chosen to eliminate the Decimal digit-count
  # blowup Decimal.div/2's/Decimal.sub/2's exact-precision output can
  # produce, not to preserve any particular number of "real" significant
  # digits.
  @default_precision 8

  # Same default rolling window every time-windowed signal kind uses
  # (Derivative, SelfZscore, Deviation's zscore kind, DefinitionSignal's
  # momentum fallback).
  @default_window_ms :timer.minutes(5)

  # Hard cap on every trim_window-style function's output, on top of its
  # own time-based trim. A time-only cutoff can't recover if the calling
  # process itself falls behind its own mailbox: DateTime.utc_now/0 at the
  # moment each late-processed message actually runs can lag further and
  # further behind wall-clock the more backlog piles up, so the cutoff
  # (computed from that stale `now`) stops actually shrinking the window
  # relative to real elapsed time. Confirmed live more than once (see this
  # module's own moduledoc) as 150,000-328,000+-message mailbox backlogs
  # with the window never time-trimmed back down. Same value every
  # extracted signal kind already used.
  @default_max_history_samples 500

  ## ---------------------------------------------------------------------
  ## Derivative / second_derivative
  ## ---------------------------------------------------------------------

  @doc """
  One tick of `derivative`/`second_derivative`-kind signal state:
  extracted from `TradingSignal.Signals.Derivative`. Rounds `new_sample`
  to `:precision` (default #{@default_precision}) before it enters
  `history`, trims `history` to the `:window_ms` (default
  #{inspect(@default_window_ms)}) trailing `now`, capped at
  `:max_history_samples` (default #{@default_max_history_samples}), then
  computes the slope — `(newest - oldest) / seconds_elapsed` — of the
  resulting window, rounded again to `:precision` on the way out.

  Returns `{new_history, nil}` when fewer than 2 samples are in the
  window, or when the newest and oldest samples in the window share the
  same timestamp (a zero-second denominator) — same "nothing to emit yet"
  cases `Derivative.slope/1` guarded against live.

  `second_derivative` needs no special handling: calling this again on a
  `derivative` signal's own emitted value stream computes the slope of the
  slope, which *is* the second derivative — exactly how the live signal
  module documents this (it never inspects its own `kind` at runtime).
  """
  @spec derivative(history(), sample(), DateTime.t(), keyword()) :: {history(), Decimal.t() | nil}
  def derivative(history, new_sample, now, opts \\ []) do
    precision = Keyword.get(opts, :precision, @default_precision)
    window_ms = Keyword.get(opts, :window_ms, @default_window_ms)
    max_history_samples = Keyword.get(opts, :max_history_samples, @default_max_history_samples)

    rounded = new_sample |> to_decimal() |> Decimal.round(precision)

    new_history =
      trim_window([{now, rounded} | history], now, window_ms, max_history_samples)

    value =
      case slope(new_history) do
        nil -> nil
        slope -> Decimal.round(slope, precision)
      end

    {new_history, value}
  end

  defp slope(history) when length(history) < 2, do: nil

  defp slope(history) do
    {newest_at, newest} = List.first(history)
    {oldest_at, oldest} = List.last(history)

    seconds_elapsed = DateTime.diff(newest_at, oldest_at, :millisecond) / 1000

    if seconds_elapsed == 0 do
      nil
    else
      newest
      |> Decimal.sub(oldest)
      |> Decimal.div(Decimal.from_float(seconds_elapsed))
    end
  end

  ## ---------------------------------------------------------------------
  ## VWAP
  ## ---------------------------------------------------------------------

  @doc """
  Session VWAP from running totals: extracted from
  `TradingSignal.Signals.Vwap.vwap/1`. `cum_pv / cum_volume`, rounded to
  `precision` (default #{@default_precision}) — `nil` when `cum_volume` is
  not positive (nothing traded yet this session).

  Rounds the *emitted* quotient — `Decimal.div/2` is exact-precision
  division, so nothing about `cum_pv`/`cum_volume` being ordinary
  price/share-count magnitudes bounds the quotient's own digit count (see
  this module's moduledoc "Rounding/precision discipline" section for the
  confirmed live incident this guards against: an unrounded division here
  fed straight into a `Deviation`/`SelfZscore`-style rolling window, which
  reduces every sample through `Decimal.to_float/1` on every tick).
  """
  @spec vwap(Decimal.t(), Decimal.t(), keyword()) :: Decimal.t() | nil
  def vwap(cum_pv, cum_volume, opts \\ []) do
    precision = Keyword.get(opts, :precision, @default_precision)

    if Decimal.compare(cum_volume, 0) == :gt do
      cum_pv
      |> Decimal.div(cum_volume)
      |> Decimal.round(precision)
    end
  end

  @doc """
  Folds one volume delta into a running `cum_pv` (cumulative
  price-times-volume), weighted by `last_price` — extracted from
  `TradingSignal.Signals.Vwap.fold_price_weighted_delta/2`. A no-op
  (`cum_pv` unchanged) when `last_price` is `nil` (no price tick has
  arrived yet to weight this delta by) or `delta` is `nil` (nothing usable
  to fold, e.g. `TradingSignal.Signals.CumulativeVolume.fold/2`'s
  first-ever-reading or non-advancing-counter cases) — same two guard
  clauses the live signal module has, preserved in the same order.
  """
  @spec fold_price_weighted_delta(Decimal.t(), Decimal.t() | nil, Decimal.t() | nil) ::
          Decimal.t()
  def fold_price_weighted_delta(cum_pv, nil, _delta), do: cum_pv
  def fold_price_weighted_delta(cum_pv, _last_price, nil), do: cum_pv

  def fold_price_weighted_delta(cum_pv, last_price, delta) do
    Decimal.add(cum_pv, Decimal.mult(last_price, delta))
  end

  ## ---------------------------------------------------------------------
  ## SelfZscore
  ## ---------------------------------------------------------------------

  @doc """
  One tick of `self_zscore`-kind signal state: extracted from
  `TradingSignal.Signals.SelfZscore`. Rounds `new_sample` to `:precision`
  (default #{@default_precision}) before it enters `history`, trims to
  `:window_ms` (default #{inspect(@default_window_ms)}) trailing `now`
  (capped at `:max_history_samples`, default
  #{@default_max_history_samples}), rebuilds a fresh `TradingCore.WelfordAcc`
  from the trimmed window (same "no cheap batch-remove" reasoning
  `WelfordAcc`'s own moduledoc explains), then computes
  `(sample - mean) / stdev`.

  Returns `{new_history, new_welford, nil}` when fewer than 2 samples
  remain in the window, or when the window's variance is exactly zero (a
  flat value — dividing by a zero stdev is undefined) — same two "nothing
  to emit yet" cases the live signal module guards against.
  """
  @spec self_zscore(history(), WelfordAcc.t(), sample(), DateTime.t(), keyword()) ::
          {history(), WelfordAcc.t(), Decimal.t() | nil}
  def self_zscore(history, _welford, new_sample, now, opts \\ []) do
    precision = Keyword.get(opts, :precision, @default_precision)
    window_ms = Keyword.get(opts, :window_ms, @default_window_ms)
    max_history_samples = Keyword.get(opts, :max_history_samples, @default_max_history_samples)

    sample = new_sample |> to_decimal() |> Decimal.round(precision)

    new_history =
      trim_window([{now, sample} | history], now, window_ms, max_history_samples)

    new_welford = rebuild_welford(new_history)
    value = zscore(sample, new_welford)

    {new_history, new_welford, value}
  end

  defp rebuild_welford(history) do
    Enum.reduce(history, WelfordAcc.new(), fn {_at, sample}, acc ->
      WelfordAcc.add(acc, Decimal.to_float(sample))
    end)
  end

  defp zscore(_sample, %{count: count}) when count < 2, do: nil

  defp zscore(sample, welford) do
    variance = WelfordAcc.variance(welford)

    if variance <= 0.0 do
      nil
    else
      stdev = :math.sqrt(variance)
      sample_f = Decimal.to_float(sample)
      Decimal.from_float((sample_f - welford.mean) / stdev)
    end
  end

  ## ---------------------------------------------------------------------
  ## Deviation: percent_deviation / ratio / zscore (spread)
  ## ---------------------------------------------------------------------

  @doc """
  `(value - reference) / reference * 100` — extracted from
  `TradingSignal.Signals.Deviation.percent_deviation/2`. `nil` when
  `reference` is zero (undefined, not a divide-by-zero error) — a real
  reachable state for some reference signals (e.g. a `derivative` sitting
  at exactly zero momentarily), not just hypothetical.
  """
  @spec percent_deviation(Decimal.t(), Decimal.t()) :: Decimal.t() | nil
  def percent_deviation(_value, reference) when reference == 0 or reference == 0.0, do: nil

  def percent_deviation(value, reference) do
    if Decimal.compare(reference, 0) == :eq do
      nil
    else
      value
      |> Decimal.sub(reference)
      |> Decimal.div(reference)
      |> Decimal.mult(100)
    end
  end

  @doc """
  `value / reference`, rounded to `precision` (default
  #{@default_precision}) — extracted from
  `TradingSignal.Signals.Deviation.ratio/2`. `nil` when `reference` is
  zero, same guard as `percent_deviation/2`.
  """
  @spec ratio(Decimal.t(), Decimal.t(), keyword()) :: Decimal.t() | nil
  def ratio(_value, reference, _opts \\ [])
  def ratio(_value, reference, _opts) when reference == 0 or reference == 0.0, do: nil

  def ratio(value, reference, opts) do
    precision = Keyword.get(opts, :precision, @default_precision)

    if Decimal.compare(reference, 0) == :eq do
      nil
    else
      value |> Decimal.div(reference) |> Decimal.round(precision)
    end
  end

  @doc """
  One tick of the `zscore`-kind `Deviation` signal's state: extracted from
  `TradingSignal.Signals.Deviation`'s `recompute/1` `"zscore"` clause. Same
  shape as `self_zscore/5` above, but over `value - reference`'s own
  history rather than a single parent's raw value stream — computes the
  spread (`Decimal.sub/2`), rounds it to `:precision` (default
  #{@default_precision}), trims/rebuilds a `TradingCore.WelfordAcc` the
  same way, and returns the zscore of the current spread against its own
  rolling mean/stdev.

  Returns `{new_history, new_welford, nil}` under the same "fewer than 2
  samples" / "zero variance" conditions `self_zscore/5` does.
  """
  @spec spread_zscore(history(), WelfordAcc.t(), Decimal.t(), Decimal.t(), DateTime.t(), keyword()) ::
          {history(), WelfordAcc.t(), Decimal.t() | nil}
  def spread_zscore(history, _welford, value, reference, now, opts \\ []) do
    precision = Keyword.get(opts, :precision, @default_precision)
    window_ms = Keyword.get(opts, :window_ms, @default_window_ms)
    max_history_samples = Keyword.get(opts, :max_history_samples, @default_max_history_samples)

    spread = value |> Decimal.sub(reference) |> Decimal.round(precision)

    new_history =
      trim_window([{now, spread} | history], now, window_ms, max_history_samples)

    new_welford = rebuild_welford(new_history)
    value = zscore(spread, new_welford)

    {new_history, new_welford, value}
  end

  ## ---------------------------------------------------------------------
  ## Wavelet
  ## ---------------------------------------------------------------------

  # Same constants TradingSignal.Signals.Wavelet uses — must be a power of
  # two (WaveletTransform's periodic-extension DWT halves the sample count
  # at every level) and j = 3 is the requested denoise depth. See
  # TradingSignal.Signals.Wavelet's own moduledoc for why these aren't
  # exposed as configurable options here either.
  @wavelet_window_size 64
  @wavelet_level 3

  @doc """
  One tick of `wavelet`-kind signal state: extracted from
  `TradingSignal.Signals.Wavelet`. Appends `new_sample` (as a float) to
  the end of `window` (newest-last, the order `TradingCore.WaveletTransform`
  expects a time series in), trims to the fixed #{@wavelet_window_size}-sample
  size (oldest dropped from the front, purely count-based — no time
  trimming here, unlike every other windowed function in this module),
  and once the window is completely full, runs it through
  `TradingCore.WaveletTransform.denoise/2` at level #{@wavelet_level} and
  returns the last point of the reconstructed series (the denoised value
  "at now").

  Returns `{new_window, nil}` while `window` has fewer than
  #{@wavelet_window_size} samples — there's no way to compute a
  meaningful DWT decomposition from a partial window (see
  `TradingSignal.Signals.Wavelet`'s own moduledoc, "Why a window, not a
  2-point delta").
  """
  @spec wavelet([float()], sample()) :: {[float()], Decimal.t() | nil}
  def wavelet(window, new_sample) do
    new_window = trim_wavelet_window(window ++ [to_float(new_sample)])

    value =
      case denoised_value(new_window) do
        nil -> nil
        value -> value
      end

    {new_window, value}
  end

  defp trim_wavelet_window(window) when length(window) > @wavelet_window_size do
    Enum.drop(window, length(window) - @wavelet_window_size)
  end

  defp trim_wavelet_window(window), do: window

  defp denoised_value(window) when length(window) < @wavelet_window_size, do: nil

  defp denoised_value(window) do
    window
    |> WaveletTransform.denoise(@wavelet_level)
    |> List.last()
    |> Decimal.from_float()
  end

  ## ---------------------------------------------------------------------
  ## Donchian
  ## ---------------------------------------------------------------------

  @doc """
  One tick of `donchian`-kind signal state: extracted from
  `TradingSignal.Signals.Donchian`. Trims `prices` to `:window_ms` trailing
  `now` (capped at `:max_history_samples`, default
  #{@default_max_history_samples}; the live signal's own default window is
  20 minutes, applied by the caller via `opts[:window_ms]` — there's no
  module-level default duration here since Donchian's live default comes
  from a per-definition `params["window"]` string, not a fixed constant),
  then emits `1` when the latest price is at or above the window's high
  (breakout), `-1` at or below the window's low (breakdown), `0` otherwise
  (inside the channel).

  Returns `{new_prices, nil}` until at least two distinct prices have
  accumulated in the window — one price alone has no high/low spread. Use
  `donchian_bands/1` to get the `{upper, middle, lower}` values themselves
  rather than just the breakout scalar, same as `Donchian.bands/1` exposes
  live.
  """
  @spec donchian(history(), sample(), DateTime.t(), keyword()) :: {history(), Decimal.t() | nil}
  def donchian(prices, new_price, now, opts \\ []) do
    window_ms = Keyword.fetch!(opts, :window_ms)
    max_history_samples = Keyword.get(opts, :max_history_samples, @default_max_history_samples)

    new_prices =
      trim_window([{now, to_decimal(new_price)} | prices], now, window_ms, max_history_samples)

    {new_prices, breakout_value(new_prices)}
  end

  @doc """
  The current `{upper, middle, lower}` Donchian band values for `prices`,
  or `nil` if fewer than two prices are in the window — extracted from
  `TradingSignal.Signals.Donchian.bands/1`/its private `compute_bands/1`.
  """
  @spec donchian_bands(history()) :: {Decimal.t(), Decimal.t(), Decimal.t()} | nil
  def donchian_bands(prices), do: compute_bands(prices)

  defp compute_bands(prices) when length(prices) < 2, do: nil

  defp compute_bands(prices) do
    values = Enum.map(prices, fn {_at, price} -> price end)
    upper = Enum.max(values, Decimal)
    lower = Enum.min(values, Decimal)
    middle = Decimal.div(Decimal.add(upper, lower), 2)
    {upper, middle, lower}
  end

  defp breakout_value(prices) do
    case compute_bands(prices) do
      nil ->
        nil

      {upper, _middle, lower} ->
        {_at, latest} = List.first(prices)

        cond do
          Decimal.compare(latest, upper) != :lt -> Decimal.new(1)
          Decimal.compare(latest, lower) != :gt -> Decimal.new(-1)
          true -> Decimal.new(0)
        end
    end
  end

  ## ---------------------------------------------------------------------
  ## Regime
  ## ---------------------------------------------------------------------

  @doc """
  The discrete `+1`/`-1`/`0` regime call: extracted from
  `TradingSignal.Signals.Regime`'s private `regime/1`. Unlike every other
  function above, this has no window/history to thread — it's a pure
  comparison of the two parents' latest known values, recomputed fresh on
  every call (mirroring how the live signal recomputes on *either*
  parent's tick using the other's last-known value — that "latest of
  each" bookkeeping is the caller's job, same as `Deviation`'s `value`/
  `reference` fields are the caller's job for `percent_deviation/2`/
  `ratio/2` above).

  `direction` is the breadth/direction vote (e.g. NYSE TICK); `gate` is
  the volatility-suppression gate's current zscore (e.g. a `self_zscore`
  of VIX). `tick_deadband` and `vix_gate_zscore` are the same
  per-definition `params`-driven thresholds the live signal reads from
  `definition.params` (defaults `300` and `1.5` respectively are the
  caller's responsibility to supply, not baked in here, since a real
  `Regime` definition can override either).

  ```
  cond do
    gate > vix_gate_zscore -> 0   # choppy — vol spiking, don't trust the vote
    direction > tick_deadband -> 1        # long
    direction < -tick_deadband -> -1      # short
    true -> 0                             # choppy — direction too weak/noisy
  end
  ```
  """
  @spec regime(Decimal.t(), Decimal.t(), Decimal.t(), Decimal.t()) :: Decimal.t()
  def regime(direction, gate, tick_deadband, vix_gate_zscore) do
    cond do
      Decimal.compare(gate, vix_gate_zscore) == :gt ->
        Decimal.new(0)

      Decimal.compare(direction, tick_deadband) == :gt ->
        Decimal.new(1)

      Decimal.compare(direction, Decimal.negate(tick_deadband)) == :lt ->
        Decimal.new(-1)

      true ->
        Decimal.new(0)
    end
  end

  ## ---------------------------------------------------------------------
  ## Momentum (Momentum + DefinitionSignal's plain momentum fallback)
  ## ---------------------------------------------------------------------

  @doc """
  One tick of windowed momentum state: extracted from
  `TradingSignal.Signals.Momentum` and, identically, from
  `TradingSignal.Signals.DefinitionSignal`'s `params`-driven (non-
  `expression`) fallback path — both compute the exact same
  `newest - oldest` value over a trimmed time window of raw price ticks,
  so one function serves both call sites rather than two copies that could
  drift apart. Distinct from `derivative/4` above: this is a bare
  difference, not divided by elapsed time, and (matching both source
  modules) is never rounded — `Decimal.sub/2` here is between two raw tick
  prices, not a chained division result, so neither source module applies
  a `@precision` round to it.

  Trims `prices` to `:window_ms` trailing `now` (capped at
  `:max_history_samples`, default #{@default_max_history_samples}; no
  module-level default duration — both call sites derive their own window
  from a per-definition/spec string like `"5m"`/`"20m"`, so the caller
  always supplies `opts[:window_ms]`).

  Returns `{new_prices, nil}` until at least two prices have accumulated
  in the window.
  """
  @spec momentum(history(), sample(), DateTime.t(), keyword()) :: {history(), Decimal.t() | nil}
  def momentum(prices, new_price, now, opts \\ []) do
    window_ms = Keyword.fetch!(opts, :window_ms)
    max_history_samples = Keyword.get(opts, :max_history_samples, @default_max_history_samples)

    new_prices =
      trim_window([{now, to_decimal(new_price)} | prices], now, window_ms, max_history_samples)

    {new_prices, momentum_value(new_prices)}
  end

  defp momentum_value(prices) when length(prices) < 2, do: nil

  defp momentum_value(prices) do
    {_newest_at, newest} = List.first(prices)
    {_oldest_at, oldest} = List.last(prices)
    Decimal.sub(newest, oldest)
  end

  ## ---------------------------------------------------------------------
  ## Shared helpers
  ## ---------------------------------------------------------------------

  # Common shape every wrapping/window-based signal kind uses: filter out
  # anything older than `window_ms` before `now`, then hard-cap at
  # `max_history_samples` on top of that (see this module's moduledoc for
  # why the hard cap exists independently of the time-based trim).
  defp trim_window(history, now, window_ms, max_history_samples) do
    cutoff = DateTime.add(now, -window_ms, :millisecond)

    history
    |> Enum.filter(fn {at, _value} -> DateTime.compare(at, cutoff) != :lt end)
    |> Enum.take(max_history_samples)
  end

  defp to_decimal(%Decimal{} = value), do: value
  defp to_decimal(value) when is_float(value), do: Decimal.from_float(value)
  defp to_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp to_decimal(value) when is_binary(value), do: Decimal.new(value)

  defp to_float(%Decimal{} = value), do: Decimal.to_float(value)
  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value * 1.0
  defp to_float(value) when is_binary(value), do: value |> Decimal.new() |> Decimal.to_float()
end
