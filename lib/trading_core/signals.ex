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

  ## Fixed-interval sampling (`derivative/4`, `self_zscore/5`, `spread_zscore/6`; opt-in for `rolling_ols_beta/4`)

  These three keep a history of past samples over `:window_ms`. They used
  to add one point per tick and trim by both `:window_ms` and
  `:max_history_samples` (500). On a busy feed (Polygon SPY/QQQ trades,
  and ratios built from them) 500 ticks cover only a few seconds, so the
  cap, not `:window_ms`, set the window. A "2h" VWAP z-score was really a
  z-score over the last few seconds. trading_signal saw this on
  2026-09-22 as near-zero minute-to-minute autocorrelation on those rows,
  while the same kinds on slow feeds looked normal.

  History is now sampled at a fixed interval, `:sample_interval_ms`
  (default `default_sample_interval_ms/1`: `window_ms / 240`, at least
  1s). Time is cut into interval-wide buckets. A tick in the same bucket
  as the newest point *replaces* it, and a tick in a new bucket adds a
  point. The window then holds about 240 points however fast ticks
  arrive, and `:window_ms` is the real window. A value is still emitted
  on every tick: the newest point is always the current tick, scored
  against the window. `sample_interval_ms: 0` turns sampling off.

  A feed whose ticks are at least one interval apart gets exactly the
  same history and values as before. A feed faster than that gets
  **different values, for every row that reads it**, so a series
  recorded before this change and one recorded after it are not
  comparable across that boundary.

  `:max_history_samples` stays as a safety net. If it ever drops points
  that are still inside `:window_ms`, the window is short again. That is
  reported rather than silent: the three functions call
  `opts[:on_cap_bound]` (a 1-arity function, if given) with
  `%{dropped:, max_history_samples:, window_ms:, sample_interval_ms:,
  oldest_kept_at:}`, and `TradingCore.Signal.Compute` counts those drops
  into its state's `:cap_bound_drops`. With the default interval, the
  default cap never binds.

  ## Spread (pairs trading): new math, not extracted from anywhere

  Unlike every function above, `rolling_ols_beta/4`, `kalman_beta/4`,
  `log_spread/5`, `spread_half_life/1`, and `spread_crossings/2` have no
  live `trading_signal` predecessor — they exist to back
  `TradingCore.Signal.Compute`'s `:spread` kind, a real hedge-ratio pairs
  spread (as opposed to `:zscore`'s fixed-beta-of-1 `value - reference`).
  Same conventions apply regardless: no wall clock, `now` as an explicit
  parameter, rounding into history before it's reused (not just on the
  emitted value), and `nil` (never a crash) for "not enough samples" or
  "undefined math" — see each function's own docs for its specific guard.
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

  # Fixed-interval sampling budget for derivative/4, self_zscore/5 and
  # spread_zscore/6: about this many points per window, never sampled
  # faster than once a second. See "Fixed-interval sampling" in the moduledoc.
  @samples_per_window 240
  @min_sample_interval_ms 1_000

  ## ---------------------------------------------------------------------
  ## Derivative / second_derivative
  ## ---------------------------------------------------------------------

  @doc """
  One tick of `derivative`/`second_derivative`-kind signal state:
  extracted from `TradingSignal.Signals.Derivative`. Rounds `new_sample`
  to `:precision` (default #{@default_precision}) before it enters
  `history`, samples it at `:sample_interval_ms` and trims it to the
  `:window_ms` (default #{inspect(@default_window_ms)}) trailing `now`,
  capped at `:max_history_samples` (default #{@default_max_history_samples};
  see "Fixed-interval sampling" in the moduledoc), then
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
    rounded = new_sample |> to_decimal() |> Decimal.round(precision)
    new_history = sample_and_trim(history, {now, rounded}, now, opts)

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
  (default #{@default_precision}) before it enters `history`, samples it at
  `:sample_interval_ms` and trims to `:window_ms` (default
  #{inspect(@default_window_ms)}) trailing `now` (capped at
  `:max_history_samples`, default #{@default_max_history_samples}; see
  "Fixed-interval sampling" in the moduledoc), rebuilds a fresh `TradingCore.WelfordAcc`
  from the trimmed window (same "no cheap batch-remove" reasoning
  `WelfordAcc`'s own moduledoc explains), then computes
  `(sample - mean) / stdev`.

  Returns `{new_history, new_welford, nil}` when fewer than 2 samples
  remain in the window, or when the window is flat enough that a z-score
  is meaningless — not merely an *exactly* zero variance, but any stdev
  negligible against the magnitude of the values themselves. A
  near-constant window (a quiet or closed tape) otherwise divides by a
  vanishing stdev and emits a large, confident, meaningless reading; see
  `zscore/2`'s own comment for the observed case and why the floor is
  relative rather than absolute.
  """
  @spec self_zscore(history(), WelfordAcc.t(), sample(), DateTime.t(), keyword()) ::
          {history(), WelfordAcc.t(), Decimal.t() | nil}
  def self_zscore(history, _welford, new_sample, now, opts \\ []) do
    precision = Keyword.get(opts, :precision, @default_precision)
    sample = new_sample |> to_decimal() |> Decimal.round(precision)
    new_history = sample_and_trim(history, history_entry(now, sample, opts), now, opts)

    new_welford = rebuild_welford(new_history)
    value = zscore(sample, new_welford)

    {new_history, new_welford, value}
  end

  defp rebuild_welford(history) do
    Enum.reduce(history, WelfordAcc.new(), fn entry, acc ->
      WelfordAcc.add(acc, entry_float(entry))
    end)
  end

  # With `cache_floats: true`, a history entry carries its float next to
  # the rounded Decimal, `{at, decimal, float}`, so the float is computed
  # once at insert instead of on every later tick the entry stays in the
  # window. It is `Decimal.to_float/1` of that same rounded Decimal, so
  # every result is bit-for-bit what the plain `{at, decimal}` entry gives.
  # Readers accept either shape, so a history can mix them.
  defp history_entry(at, decimal, opts) do
    if Keyword.get(opts, :cache_floats, false),
      do: {at, decimal, Decimal.to_float(decimal)},
      else: {at, decimal}
  end

  defp entry_float({_at, _decimal, float}), do: float
  defp entry_float({_at, decimal}), do: Decimal.to_float(decimal)

  # Relative floor on the standard deviation, below which a z-score is
  # reported as `nil` rather than as a number.
  #
  # A bare `variance <= 0.0` check only catches an *exactly* constant
  # window. A near-constant one — every sample identical to ~8 decimal
  # places, which is what a quiet or closed tape produces — yields a
  # variance around 1e-17 that passes that check and then divides a
  # small numerator by a vanishing stdev, emitting a large, confident,
  # meaningless reading. Observed live: `massive_spy_vwap_zscore` at
  # -11.49 on a closed Saturday tape, and reproduced here at variance
  # 9.17e-17 => z = 1.31 from four samples differing only in the 8th
  # decimal. Rounding the inputs does not prevent it (samples that differ
  # in the 8th decimal survive precision-8 rounding), and a wider window
  # only makes it rarer — any sufficiently quiet window reaches it.
  #
  # The floor is relative rather than absolute because this helper serves
  # both `self_zscore/5` (wrapping whatever series its parent emits — a
  # VIX level near 20, a price near 500) and `spread_zscore/6` (a spread
  # that may sit near 0.15). No single absolute epsilon is right across
  # those units.
  #
  # Scaled against the larger of |mean| and |sample|, never |mean| alone:
  # a spread oscillating symmetrically around zero has a mean of ~1e-17
  # with a genuinely large stdev (0.51 in a reproduced case), so a
  # mean-only scale would compute a ~1e-26 floor there and suppress
  # nothing. Taking the magnitude of the observation as well keeps the
  # floor meaningful exactly where the mean vanishes. When both are ~0 the
  # series is degenerate in absolute terms too, so the absolute fallback
  # below is the correct reading.
  # Calibrated against real cases rather than picked round. Measuring
  # stdev/scale on each: the 8th-decimal-jitter window that must be
  # suppressed sits at 9.6e-9, while the tightest *legitimate* window
  # checked — a price series moving 0.01% — sits at 1.3e-4, and an
  # ordinary VIX window at 6.2e-2. 1e-6 falls between those two clusters
  # with ~100x margin on either side, so it suppresses the degenerate
  # case without touching a genuinely quiet but real one. The absolute
  # fallback catches a series where both mean and sample are ~0, where
  # any ratio is meaningless.
  @degenerate_stdev_ratio 1.0e-6
  @degenerate_stdev_absolute 1.0e-12

  defp zscore(_sample, %{count: count}) when count < 2, do: nil

  defp zscore(sample, welford) do
    variance = WelfordAcc.variance(welford)
    sample_f = Decimal.to_float(sample)

    if degenerate_variance?(variance, welford.mean, sample_f) do
      nil
    else
      stdev = :math.sqrt(variance)
      Decimal.from_float((sample_f - welford.mean) / stdev)
    end
  end

  defp degenerate_variance?(variance, _mean, _sample) when variance <= 0.0, do: true

  defp degenerate_variance?(variance, mean, sample) do
    stdev = :math.sqrt(variance)
    scale = max(abs(mean), abs(sample))
    floor = max(scale * @degenerate_stdev_ratio, @degenerate_stdev_absolute)

    stdev < floor
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

  Rounds the *emitted* result to `precision` (default
  #{@default_precision}), same discipline as `vwap/3`/`ratio/3` — `Decimal.div/2`
  is exact-precision, so an entirely ordinary-looking `value`/`reference`
  pair (e.g. `100.03`/`99.97`) can still produce a 30+ significant-digit
  quotient (confirmed: a `0.06%`-ish deviation from realistic inputs came
  back as 36 digits before this rounded). Left unrounded, that value is
  exactly the shape of `Decimal` this module's own moduledoc ("Rounding/
  precision discipline is load-bearing") warns against handing to any
  caller that might fold it into a rolling window/Welford accumulator —
  `TradingCore.Signal.Compute` can wire this function's own output into
  exactly such a window (a `percent_deviation` node feeding a
  `derivative`/`self_zscore` child in a spec tree), so this can no longer
  be treated as "just a terminal value nothing re-consumes."
  """
  @spec percent_deviation(Decimal.t(), Decimal.t(), keyword()) :: Decimal.t() | nil
  def percent_deviation(value, reference, opts \\ [])
  def percent_deviation(_value, reference, _opts) when reference == 0 or reference == 0.0, do: nil

  def percent_deviation(value, reference, opts) do
    precision = Keyword.get(opts, :precision, @default_precision)

    if Decimal.compare(reference, 0) == :eq do
      nil
    else
      value
      |> Decimal.sub(reference)
      |> Decimal.div(reference)
      |> Decimal.mult(100)
      |> Decimal.round(precision)
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
  #{@default_precision}), samples/trims/rebuilds a `TradingCore.WelfordAcc`
  the same way, and returns the zscore of the current spread against its own
  rolling mean/stdev.

  Returns `{new_history, new_welford, nil}` under the same "fewer than 2
  samples" / "degenerate variance" conditions `self_zscore/5` does — the
  latter matters more here than for `self_zscore/5`, since a spread
  against a slow-moving reference is exactly the series that goes
  near-constant on a quiet tape.
  """
  @spec spread_zscore(
          history(),
          WelfordAcc.t(),
          Decimal.t(),
          Decimal.t(),
          DateTime.t(),
          keyword()
        ) ::
          {history(), WelfordAcc.t(), Decimal.t() | nil}
  def spread_zscore(history, _welford, value, reference, now, opts \\ []) do
    precision = Keyword.get(opts, :precision, @default_precision)
    spread = value |> Decimal.sub(reference) |> Decimal.round(precision)
    new_history = sample_and_trim(history, {now, spread}, now, opts)

    new_welford = rebuild_welford(new_history)
    value = zscore(spread, new_welford)

    {new_history, new_welford, value}
  end

  ## ---------------------------------------------------------------------
  ## Two-scale realized volatility
  ## ---------------------------------------------------------------------

  @doc """
  Two-scale realized volatility (Zhang/Mykland/Aït-Sahalia) over
  `prices`, oldest first.

  Returns the noise-corrected **variance** over the window (not
  annualised, not a standard deviation), or `nil` when the slow scale has
  too few samples to be estimable.

  ## Why not just sum squared returns

  Naive realized volatility — summing squared tick-to-tick log returns —
  is dominated by microstructure noise, and sampling *faster* makes it
  worse rather than better: every print carries bid-ask bounce, so each
  additional observation adds more noise than signal. On a simulated
  random walk with 4bp iid noise, naive RV overstated true variance by
  roughly 9x (1.49e-4 against a true 1.61e-5) while this estimator
  recovered 1.57e-5, within 2%.

  The correction computes RV two ways: `RV_all` on every return (mostly
  noise) and `RV_avg`, the average of the RVs computed on `k` interleaved
  subgrids (much less noise, because each subgrid samples `k` ticks
  apart). Noise enters both with a known relative weight, so

      TSRV = RV_avg - (nbar / n) * RV_all      where nbar = (n - k + 1) / k

  cancels it to first order. `k` is the subsampling factor: larger means
  a slower second scale and more noise removed, at the cost of a noisier
  estimate from fewer points per subgrid.

  Returns `nil` rather than a number when fewer than `k + 1` prices are
  available (no subgrid would have two points to difference) — and
  **clamps a negative result to zero**: the correction can overshoot on a
  short or unusually quiet window, and a negative variance is not a
  small variance, it is an estimator failure. Reporting it as `0.0` keeps
  the value in a domain callers can take a square root of.
  """
  @spec two_scale_rv([sample()], pos_integer()) :: float() | nil
  def two_scale_rv(prices, k) when is_integer(k) and k > 0 do
    logs = Enum.map(prices, &(&1 |> to_float() |> :math.log()))
    n = length(logs) - 1

    if n < k + 1 do
      nil
    else
      rv_all = sum_squared_diffs(logs)

      rv_avg =
        0..(k - 1)
        |> Enum.map(fn offset -> logs |> Enum.drop(offset) |> Enum.take_every(k) end)
        |> Enum.map(&sum_squared_diffs/1)
        |> Enum.sum()
        |> Kernel./(k)

      nbar = (n - k + 1) / k

      max(rv_avg - nbar / n * rv_all, 0.0)
    end
  end

  @doc """
  Naive realized volatility — the sum of squared log returns over
  `prices`, oldest first.

  Exposed for comparison against `two_scale_rv/2` rather than for use as
  a volatility estimate on tick data: on anything sampled at trade
  frequency this is the noise-dominated number the two-scale estimator
  exists to correct. It is the right estimator only when the sampling
  interval is long enough that microstructure noise is negligible
  relative to the return — think 5-minute bars, not prints.
  """
  @spec naive_rv([sample()]) :: float() | nil
  def naive_rv(prices) when length(prices) < 2, do: nil

  def naive_rv(prices) do
    prices
    |> Enum.map(&(&1 |> to_float() |> :math.log()))
    |> sum_squared_diffs()
  end

  defp sum_squared_diffs(logs) do
    logs
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(0.0, fn [a, b], acc ->
      d = b - a
      acc + d * d
    end)
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
  ## Spread (pairs trading): rolling-OLS / Kalman beta, log-spread zscore,
  ## half-life, crossing count
  ## ---------------------------------------------------------------------

  @doc """
  Incremental rolling-OLS estimate of `(beta, alpha)` in `log_y = beta *
  log_x + alpha`, refit from scratch over the trimmed `(at, log_x, log_y)`
  window on every call — same "no cheap batch-remove" tradeoff
  `self_zscore/5` already accepts for its own `WelfordAcc` (see that
  function's docs and `TradingCore.WelfordAcc`'s own moduledoc): a rolling
  window can drop arbitrarily many stale samples in one step, and there is
  no incremental OLS update that handles removal as cheaply as addition, so
  this recomputes the closed-form OLS sums over whatever remains in the
  window rather than trying to maintain a streaming accumulator.

  `new_sample` is `{log_x, log_y}` — the caller (`TradingCore.Signal.Compute`'s
  `:spread` clause) is responsible for taking logs of the raw prices before
  calling this; kept out of this function so it composes with `kalman_beta/4`
  under one contract (`{beta, alpha}` from whatever `(x, y)` pairs it's
  given) regardless of whether the caller wants log-space or raw-price
  regression.

  Rounds `log_x`/`log_y` to `:precision` (default #{@default_precision})
  before they enter `history` — same discipline as every other windowed
  function here (see this module's moduledoc, "Rounding/precision
  discipline").

  Unlike `derivative/4`, `self_zscore/5` and `spread_zscore/6`, this keeps
  one point per tick by default. Passing `:sample_interval_ms` (and
  optionally `:on_cap_bound`) opts into the same fixed-interval sampling
  (see "Fixed-interval sampling" in the moduledoc). `:spread` opts in;
  `:kyle_lambda` does not.

  Returns `{new_history, nil}` until at least 2 samples are in the window,
  or when `log_x`'s variance in the window is exactly zero (a vertical/
  undefined regression line — every `log_x` sample identical).
  """
  @spec rolling_ols_beta(
          [{DateTime.t(), Decimal.t(), Decimal.t()}],
          {sample(), sample()},
          DateTime.t(),
          keyword()
        ) :: {[{DateTime.t(), Decimal.t(), Decimal.t()}], {Decimal.t(), Decimal.t()} | nil}
  def rolling_ols_beta(history, {log_x, log_y}, now, opts \\ []) do
    precision = Keyword.get(opts, :precision, @default_precision)
    window_ms = Keyword.get(opts, :window_ms, @default_window_ms)
    max_history_samples = Keyword.get(opts, :max_history_samples, @default_max_history_samples)

    rounded_x = log_x |> to_decimal() |> Decimal.round(precision)
    rounded_y = log_y |> to_decimal() |> Decimal.round(precision)

    # Per tick unless the caller asks for sampling: kyle_lambda relies on
    # one point per tick here, and only :spread opts in.
    trim_opts =
      opts
      |> Keyword.put(:window_ms, window_ms)
      |> Keyword.put(:max_history_samples, max_history_samples)
      |> Keyword.put_new(:sample_interval_ms, 0)

    entry =
      if Keyword.get(opts, :cache_floats, false),
        do: {now, rounded_x, rounded_y, Decimal.to_float(rounded_x), Decimal.to_float(rounded_y)},
        else: {now, rounded_x, rounded_y}

    new_history = sample_and_trim(history, entry, now, trim_opts)

    value =
      case ols(new_history) do
        nil -> nil
        {beta, alpha} -> {Decimal.round(beta, precision), Decimal.round(alpha, precision)}
      end

    {new_history, value}
  end

  defp ols(history) when length(history) < 2, do: nil

  defp ols(history) do
    xs = Enum.map(history, &ols_x/1)
    ys = Enum.map(history, &ols_y/1)
    n = length(xs)

    mean_x = Enum.sum(xs) / n
    mean_y = Enum.sum(ys) / n

    {cov_xy, var_x} =
      Enum.zip(xs, ys)
      |> Enum.reduce({0.0, 0.0}, fn {x, y}, {cov, var} ->
        dx = x - mean_x
        {cov + dx * (y - mean_y), var + dx * dx}
      end)

    if var_x == 0.0 do
      nil
    else
      beta = cov_xy / var_x
      alpha = mean_y - beta * mean_x
      {Decimal.from_float(beta), Decimal.from_float(alpha)}
    end
  end

  # {at, x, y} or, with `cache_floats: true`, {at, x, y, x_float, y_float}.
  # See history_entry/3.
  defp ols_x({_at, _x, _y, x_float, _y_float}), do: x_float
  defp ols_x({_at, x, _y}), do: Decimal.to_float(x)
  defp ols_y({_at, _x, _y, _x_float, y_float}), do: y_float
  defp ols_y({_at, _x, y}), do: Decimal.to_float(y)

  @doc """
  Kalman-filter estimate of `(beta, alpha)` in `log_y = beta * log_x +
  alpha`, treating `[beta, alpha]` as a slowly-drifting 2-vector state
  (a random walk — `process_var` is the per-tick variance added to each
  component) observed noisily through `log_y = [log_x, 1] . [beta, alpha] +
  noise` (`obs_var` is that noise's variance). Same `{beta, alpha}` output
  contract as `rolling_ols_beta/4` so `TradingCore.Signal.Compute`'s
  `:spread` clause can dispatch on `beta_mode` without either caller
  needing a different result shape.

  `state` is `{mean, cov}` — the filter's own `[beta, alpha]` estimate and
  its `2x2` covariance, both as plain `{float, float}`/`{{float, float},
  {float, float}}` tuples (no matrix library dependency for a 2x2 system).
  `nil` state means "not yet initialized" — the first call seeds `mean`
  from `{0.0, 0.0}` with a wide initial covariance, since a single sample
  can't estimate a 2-parameter fit; the caller should expect `nil` back for
  `value` on this first call, then real values from the second call on
  (mirrors every other kind's "warm up before first value" rule, even
  though a Kalman filter technically produces *some* number for both
  fields from tick one — that number is not yet meaningfully converged).

  `opts`: `:process_var` (default `1.0e-5`), `:obs_var` (default `1.0e-3`),
  `:precision` (default #{@default_precision}, applied to the emitted
  `beta`/`alpha` only — the filter's own internal state stays full-float
  precision across calls, same reasoning `WelfordAcc` keeps its running
  `mean`/`m2` as raw floats rather than rounding between ticks).
  """
  @spec kalman_beta(
          {{float(), float()}, {{float(), float()}, {float(), float()}}} | nil,
          {sample(), sample()},
          non_neg_integer(),
          keyword()
        ) ::
          {{{float(), float()}, {{float(), float()}, {float(), float()}}},
           {Decimal.t(), Decimal.t()} | nil}
  def kalman_beta(state, {log_x, log_y}, sample_count, opts \\ []) do
    precision = Keyword.get(opts, :precision, @default_precision)
    process_var = Keyword.get(opts, :process_var, 1.0e-5)
    obs_var = Keyword.get(opts, :obs_var, 1.0e-3)

    {mean, cov} = state || {{0.0, 0.0}, {{1.0e6, 0.0}, {0.0, 1.0e6}}}

    x = to_float(log_x)
    y = to_float(log_y)

    {new_mean, new_cov} = kalman_step(mean, cov, x, y, process_var, obs_var)

    value =
      if sample_count < 1 do
        nil
      else
        {beta, alpha} = new_mean

        {Decimal.round(Decimal.from_float(beta), precision),
         Decimal.round(Decimal.from_float(alpha), precision)}
      end

    {{new_mean, new_cov}, value}
  end

  # Standard 2-state Kalman predict/update, specialized to a scalar
  # observation `y = h . [beta, alpha]` with `h = [x, 1]`. Predict step adds
  # `process_var` to both diagonal covariance entries (random-walk state,
  # no off-diagonal process noise); update step is the textbook
  # `K = P h' / (h P h' + r)`, `mean' = mean + K (y - h . mean)`,
  # `P' = (I - K h) P`, written out by hand for a 2x2 system rather than
  # pulling in a matrix library for one filter.
  defp kalman_step({beta, alpha}, {{p11, p12}, {p21, p22}}, x, y, process_var, obs_var) do
    # Predict.
    p11 = p11 + process_var
    p22 = p22 + process_var

    # Innovation covariance: h P h' + r, with h = [x, 1].
    s = x * x * p11 + 2 * x * p12 + p22 + obs_var

    # Kalman gain: P h' / s.
    k1 = (x * p11 + p12) / s
    k2 = (x * p21 + p22) / s

    residual = y - (x * beta + alpha)

    new_beta = beta + k1 * residual
    new_alpha = alpha + k2 * residual

    new_p11 = p11 - k1 * (x * p11 + p12)
    new_p12 = p12 - k1 * (x * p12 + p22)
    new_p21 = p21 - k2 * (x * p11 + p12)
    new_p22 = p22 - k2 * (x * p12 + p22)

    {{new_beta, new_alpha}, {{new_p11, new_p12}, {new_p21, new_p22}}}
  end

  @doc """
  The log-space pairs spread `log_y - beta * log_x - alpha`, rounded to
  `:precision` (default #{@default_precision}) — the quantity
  `TradingCore.Signal.Compute`'s `:spread` clause feeds into `self_zscore/5`
  to get the mean-reversion z-score, once `rolling_ols_beta/4`/
  `kalman_beta/4` (or a fixed `static`-mode `beta`/`alpha`) has produced
  this tick's `beta`/`alpha`. Log-space (rather than a raw `y - beta * x`
  subtraction) is what keeps `beta` stable regardless of the pair's price
  level — see this kind's own design doc for why raw-price spread isn't
  offered as an alternative here.
  """
  @spec log_spread(sample(), sample(), Decimal.t(), Decimal.t(), keyword()) :: Decimal.t()
  def log_spread(log_x, log_y, beta, alpha, opts \\ []) do
    precision = Keyword.get(opts, :precision, @default_precision)

    log_y
    |> to_decimal()
    |> Decimal.sub(Decimal.mult(beta, to_decimal(log_x)))
    |> Decimal.sub(alpha)
    |> Decimal.round(precision)
  end

  @doc """
  Half-life of mean reversion for a rolling window of spread values, in the
  same time unit as the window's own sample spacing (informally "number of
  ticks" unless the caller's `history` is evenly time-spaced — see below).
  Fits `phi` via OLS of `spread_t` on `spread_{t-1}` (an AR(1) coefficient:
  `spread_t = phi * spread_{t-1} + c`), then `half_life = -ln(2) / ln(phi)`.

  Returns `nil` when fewer than 3 samples are in `history` (need at least 2
  consecutive pairs to fit an AR(1) slope), or when the fitted `phi` isn't
  strictly inside `(0, 1)` — `phi <= 0` or `phi >= 1` means the series isn't
  mean-reverting (a random walk or explosive/oscillating series has no
  finite half-life), same "undefined, not a crash" contract every other
  guard in this module uses (`percent_deviation/3`'s zero-reference case,
  `self_zscore/5`'s zero-variance case).

  `history` is the same `history()` shape every other windowed function
  here uses (newest-first `{DateTime.t(), Decimal.t()}` pairs) — pass the
  same trimmed window `rolling_ols_beta/4`'s sibling z-score step already
  maintains, so this reuses that window rather than keeping its own copy.
  """
  @spec spread_half_life(history()) :: float() | nil
  def spread_half_life(history) when length(history) < 3, do: nil

  def spread_half_life(history) do
    values = history |> Enum.map(&entry_float/1) |> Enum.reverse()

    laggeds = Enum.slice(values, 0, length(values) - 1)
    currents = Enum.slice(values, 1, length(values) - 1)

    n = length(laggeds)
    mean_lag = Enum.sum(laggeds) / n
    mean_cur = Enum.sum(currents) / n

    {cov, var_lag} =
      Enum.zip(laggeds, currents)
      |> Enum.reduce({0.0, 0.0}, fn {lag, cur}, {cov, var} ->
        dl = lag - mean_lag
        {cov + dl * (cur - mean_cur), var + dl * dl}
      end)

    if var_lag == 0.0 do
      nil
    else
      phi = cov / var_lag

      if phi > 0.0 and phi < 1.0 do
        -:math.log(2) / :math.log(phi)
      end
    end
  end

  @doc """
  Count of sign changes of `(spread - rolling_mean)` across `history` —
  how many times the spread has crossed its own rolling mean, a staleness/
  regime-change gate a strategy can use alongside the z-score itself (a
  pair whose spread hasn't crossed its mean in a long time despite a large
  |z| may be trending away rather than about to revert).

  `mean` is the window's current mean (the same `WelfordAcc.t()` mean the
  z-score step already computed — pass `welford.mean` rather than
  recomputing it here, so this never disagrees with the z-score's own
  notion of "the mean"). `history` is the same newest-first window
  `spread_half_life/1` takes.

  Returns `0` for a window with fewer than 2 samples (nothing to compare
  against) rather than `nil` — unlike half-life, "no crossings observed
  yet" is a meaningful count, not an undefined quantity.
  """
  @spec spread_crossings(history(), float()) :: non_neg_integer()
  def spread_crossings(history, _mean) when length(history) < 2, do: 0

  def spread_crossings(history, mean) do
    history
    |> Enum.map(&(entry_float(&1) - mean))
    |> Enum.reverse()
    |> Enum.map(&sign/1)
    |> Enum.reject(&(&1 == 0))
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.count(fn [a, b] -> a != b end)
  end

  defp sign(x) when x > 0, do: 1
  defp sign(x) when x < 0, do: -1
  defp sign(_x), do: 0

  ## ---------------------------------------------------------------------
  ## Shared helpers
  ## ---------------------------------------------------------------------

  @doc """
  The default fixed sampling interval for a `window_ms` window, used by
  `derivative/4`, `self_zscore/5` and `spread_zscore/6` when no
  `:sample_interval_ms` is given: `max(div(window_ms, #{@samples_per_window}), #{@min_sample_interval_ms})`.
  This keeps about #{@samples_per_window} points in any window, so a 2h
  window samples every 30s and a 5m window every 1.25s. See "Fixed-interval
  sampling" in this module's moduledoc.
  """
  @spec default_sample_interval_ms(pos_integer()) :: pos_integer()
  def default_sample_interval_ms(window_ms) do
    max(div(window_ms, @samples_per_window), @min_sample_interval_ms)
  end

  # Fixed-interval sampling plus the time trim and the hard cap, shared by
  # derivative/4, self_zscore/5 and spread_zscore/6. Time is cut into
  # buckets of `sample_interval_ms`, aligned to the Unix epoch. When `entry`
  # lands in the same bucket as the newest history point, it replaces that
  # point instead of adding a new one. The history then holds at most
  # one point per bucket, the last tick seen in it, however fast ticks
  # arrive. Two ticks at least one interval apart are always in different
  # buckets, so a feed slower than the interval appends every tick, as before.
  #
  # Buckets, rather than "replace while the newest point is younger than the
  # interval": a replaced point takes the new tick's timestamp, so under
  # that rule the newest point would never age and history would never
  # grow. Keeping the old timestamp instead would misdate the newest value,
  # which derivative/4's slope reads directly.
  #
  # `sample_interval_ms: 0` turns sampling off (one point per tick).
  # Entries are any tuple whose first element is its timestamp:
  # `{at, value}` here, `{at, x, y}` for rolling_ols_beta/4.
  defp sample_and_trim(history, entry, now, opts) do
    now_at = elem(entry, 0)
    window_ms = Keyword.get(opts, :window_ms, @default_window_ms)
    max_history_samples = Keyword.get(opts, :max_history_samples, @default_max_history_samples)

    interval_ms =
      Keyword.get_lazy(opts, :sample_interval_ms, fn -> default_sample_interval_ms(window_ms) end)

    sampled =
      case history do
        [head | rest] when interval_ms > 0 ->
          if bucket(elem(head, 0), interval_ms) == bucket(now_at, interval_ms),
            do: [entry | rest],
            else: [entry | history]

        _ ->
          [entry | history]
      end

    cutoff = DateTime.add(now, -window_ms, :millisecond)
    in_window = Enum.filter(sampled, &(DateTime.compare(elem(&1, 0), cutoff) != :lt))
    {kept, dropped} = Enum.split(in_window, max_history_samples)

    if dropped != [] do
      report_cap_bound(opts, %{
        dropped: length(dropped),
        max_history_samples: max_history_samples,
        window_ms: window_ms,
        sample_interval_ms: interval_ms,
        oldest_kept_at: kept |> List.last() |> elem(0)
      })
    end

    kept
  end

  defp bucket(at, interval_ms),
    do: Integer.floor_div(DateTime.to_unix(at, :millisecond), interval_ms)

  defp report_cap_bound(opts, info) do
    case Keyword.get(opts, :on_cap_bound) do
      nil -> :ok
      callback when is_function(callback, 1) -> callback.(info)
    end
  end

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
