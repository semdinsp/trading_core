defmodule TradingCore.Signal.Compute do
  @moduledoc """
  Unified entry point over every signal kind's pure math — `init/1` builds
  opaque per-signal state from a `TradingCore.Signal.Spec`, `step/2` folds
  one tick through it, and `replay/3` runs a whole tick series (against a
  possibly-nested spec tree) in one call.

  This module doesn't invent new arithmetic — every kind dispatches
  straight to the already-extracted, already-live-proven functions in
  `TradingCore.Signals` (momentum/derivative/vwap/self_zscore/spread_zscore/
  wavelet/donchian/regime), `TradingCore.WelfordAcc`, and
  `TradingCore.WaveletTransform`. What this module adds on top:

    1. **One state shape per kind**, opaque to the caller, so `step/2` has
       a single `(state, tick) -> {state, value}` signature regardless of
       which kind it's driving — a caller (a live GenServer or a replay
       loop) never needs a kind-specific case statement of its own.
    2. **Explicit warm-up** — `step/2` returns `:warming_up` instead of a
       value until the kind's own minimum-samples rule is satisfied (see
       "Warm-up" below), so live and replay agree, tick for tick, on the
       first index at which a value exists.
    3. **DAG resolution** — `replay/3` walks a `Spec` tree (built from
       `:parent`/`:reference` links) in topological order and evaluates
       each node exactly once per tick, feeding each derived kind its
       parent's/reference's own emitted value stream rather than the raw
       input series.

  No GenServer, no `Ecto`, no wall clock, no feed: nothing in this module
  calls `DateTime.utc_now/0`, reads a database, or subscribes to
  `Phoenix.PubSub`. Every notion of "now" is a `DateTime.t()` carried on
  the tick itself, and every session-boundary rule (see "Session
  boundaries" below) is an injected function, not a hardcoded market-hours
  assumption. This is what makes `replay/3` over historical data
  reproduce, byte for byte, whatever a live caller computed by calling
  `step/2` tick by tick — the entire reason this module exists (see
  `TradingCore.Signals`'s own moduledoc for the same principle applied to
  the individual arithmetic functions this module composes).

  ## The tick shape

  A tick is a plain map: `%{at: DateTime.t(), value: sample, volume:
  sample | nil}` at minimum, where `sample` is anything
  `TradingCore.Signals`'s functions already accept (`Decimal.t()`,
  `float()`, `integer()`, or a numeric `String.t()`). `:volume` is only
  read by the `:volume`/`:vwap`/`:rolling_volume` kinds (see each kind's
  own `step/2` clause for exactly which key(s) it reads); every other kind
  only reads `:value`. A caller adapting a live `TradingHub.Message`-shaped
  PubSub tick into this shape is expected to do that translation itself —
  this module has no opinion on PubSub message formats, same as
  `TradingCore.Signals` already has none.

  For a wrapping kind (single- or dual-parent), `replay/3` synthesizes the
  tick it feeds to the child: `%{at: parent_tick.at, value:
  parent_emitted_value}` — the parent's own emission timestamp and value,
  not the raw input tick. This is why every kind's `state` only needs to
  understand the one tick shape above, regardless of how deep it sits in
  the DAG.

  ## Warm-up

  Every kind's `step/2` returns `{new_state, :warming_up}` — never a
  `nil` value, and never silently omitting the tick — until its own
  underlying `TradingCore.Signals` function (or `WaveletTransform`, for
  `:wavelet`) would first return a real value. This mirrors exactly the
  "returns `{new_history, nil}`"/"returns `{new_window, nil}`" clauses
  those functions already document; `Compute` simply gives that condition
  a name so both a live driver and `replay/3` can tell "genuinely nothing
  to emit yet" apart from any other case, and so the two are provably
  looking at the same rule (there is only one implementation of "is this
  kind warmed up," inside the wrapped `TradingCore.Signals` function
  itself — `Compute` never reimplements a warm-up check separately from
  the computation it gates).

  ## Session boundaries are injected, never derived from wall-clock

  A `:vwap`, `:volume`, or `:zscore` spec's `params` may include
  `"session_reset"`, a 1-arity function `DateTime.t() -> Date.t() | term()`
  — `step/2` calls it once per tick to get "which session does this tick
  belong to," and resets the kind's own session-scoped state whenever it
  returns a different value than the previous tick's call did: the running
  total(s) back to zero for `:vwap`/`:volume` (and, for `:volume`,
  `last_reading` back to `nil` — see `maybe_reset_volume_session/3`'s own
  comment for why that part matters), or the accumulated spread window for
  `:zscore` (see `maybe_reset_zscore_session/3`, which also explains why
  that one is opt-in rather than always-on — briefly: enabling it yields a
  *different* signal rather than a corrected one, reporting `:warming_up`
  around a session open where the unreset version reports a number, so
  values either side of the change are not comparable and a consumer
  holding history needs to know when it was switched on). There is no default that reaches for
  `DateTime.utc_now/0` or hardcodes `9:30am America/New_York` inside this
  module — a caller replaying historical data supplies the exact same
  session-boundary function a live caller would (canonically
  `TradingCore.Session.us_equities/1`, built on `TradingCore.MarketHours`
  — see that module's own moduledoc for why it was chosen as the shared
  default over reproducing `TradingSignal.Signals.CumulativeVolume`'s own
  simpler 9:30am ET rule verbatim), so a session reset lands on the
  identical tick in both live and replay. See `TradingCore.Signals`'s
  "What's deliberately NOT extracted here" for why the *live*
  session-tracking module (`CumulativeVolume`) itself stays in
  `trading_signal` — this is only the injection point that lets a session
  rule be replayed identically, not a port of that module.

  ## Kinds and their `Spec` shape

  See each `step/2` clause below for the exact `params`/`window_ms`/
  `parent`/`reference` fields a kind reads. Summary, mirroring
  `TradingCore.Signal.Spec`'s own base/single-parent/dual-parent split:

    * base (own `:symbol`/`:source`, raw ticks): `:plain`, `:momentum`,
      `:volume`, `:vwap`, `:donchian`, `:rolling_volume`, `:spread` (owns
      *two* symbols — see `Spec`'s own moduledoc, "Why `:spread` is a base
      kind")
    * single-parent (wraps `:parent`'s emitted values): `:derivative`,
      `:second_derivative`, `:wavelet`, `:self_zscore`
    * dual-parent (`:parent` vs. `:reference`): `:percent_deviation`,
      `:zscore`, `:ratio`, `:regime`

  ## `:spread`'s output is a z-score, like every other kind — extras live on `state`

  `:spread`'s `step/2` still returns `{new_state, value() | :warming_up}`
  with `value()` a plain `Decimal.t()` z-score, same as every other kind —
  `@type value :: Decimal.t()` is not widened. Beta, alpha, half-life, and
  crossing-count (the extra outputs the pairs-trading design calls for) are
  not threaded through `step/2`'s return; they're read off `state` directly
  via `spread_extras/1`.

  This was a deliberate choice over the alternative (widening `value()` to
  `Decimal.t() | map()` for this one kind): every other node in a `Spec`
  tree — `replay/3`'s `tick_for/4` clauses, `warm/1`, a live caller wiring
  one kind's output into another as `:parent`/`:reference` — assumes
  "a kind's value is a scalar I can hand to the next kind's `Decimal`
  arithmetic unchanged." Making `:spread` return a map would mean either
  every consumer of a `:parent`/`:reference` value gains a
  "which field, if this came from a `:spread` node" branch, or `:spread`
  becomes unusable as an upstream node to any other kind (a strategy that
  wants `derivative` of a spread's z-score, say) without new plumbing. A
  strategy that wants beta to size its second leg already holds the same
  `state` `step/2`/`replay/3` handed it back — `spread_extras/1` reads
  beta/alpha/half-life/crossings off that state on demand, with no change
  to the value type, the DAG-composition rules, or `replay/3` itself.
  """

  alias TradingCore.Signal.Spec
  alias TradingCore.{Signals, WelfordAcc}

  @type tick :: %{
          required(:at) => DateTime.t(),
          required(:value) => Signals.sample() | nil,
          optional(:volume) => Signals.sample() | nil
        }

  @type state :: term()
  @type value :: Decimal.t()

  ## -----------------------------------------------------------------------
  ## init/1
  ## -----------------------------------------------------------------------

  @doc """
  Fresh, empty state for `spec`'s own kind — no samples seen yet. Does
  *not* recurse into `spec.parent`/`spec.reference`; `replay/3` calls this
  once per node in the resolved DAG. A caller driving a single node
  directly (the live-GenServer use case, one `Compute` state per running
  signal process, same as `TradingSignal.Signals.Process` already keeps
  one `behaviour_state` per process) calls this once per spec at its own
  init time.
  """
  @spec init(Spec.t()) :: {:ok, state()}
  def init(%Spec{kind: :plain}), do: {:ok, %{}}

  def init(%Spec{kind: kind}) when kind in [:derivative, :second_derivative] do
    {:ok, %{history: []}}
  end

  def init(%Spec{kind: :momentum}), do: {:ok, %{prices: []}}

  def init(%Spec{kind: :wavelet}), do: {:ok, %{window: []}}

  def init(%Spec{kind: :volume}) do
    {:ok, %{cum_volume: Decimal.new(0), last_reading: nil, session: nil}}
  end

  def init(%Spec{kind: :vwap}) do
    {:ok,
     %{
       cum_pv: Decimal.new(0),
       cum_volume: Decimal.new(0),
       last_price: nil,
       session: nil
     }}
  end

  def init(%Spec{kind: :donchian}), do: {:ok, %{prices: []}}

  def init(%Spec{kind: :rolling_volume}), do: {:ok, %{readings: []}}

  def init(%Spec{kind: :self_zscore}), do: {:ok, %{history: [], welford: WelfordAcc.new()}}

  def init(%Spec{kind: kind})
      when kind in [:percent_deviation, :ratio] do
    {:ok, %{value: nil, reference: nil}}
  end

  def init(%Spec{kind: :zscore}) do
    {:ok, %{value: nil, reference: nil, history: [], welford: WelfordAcc.new(), session: nil}}
  end

  def init(%Spec{kind: :regime}), do: {:ok, %{direction: nil, gate: nil}}

  def init(%Spec{kind: :spread} = spec) do
    beta_mode = Map.get(spec.params, "beta_mode", "static")

    beta_state =
      case beta_mode do
        "rolling_ols" -> %{history: []}
        "kalman" -> %{filter: nil, sample_count: 0}
        "static" -> static_beta_alpha(spec.params)
      end

    {:ok,
     %{
       beta_mode: beta_mode,
       beta_state: beta_state,
       beta: nil,
       alpha: nil,
       # Last-known price of each leg, with the timestamp it arrived on,
       # so a tick carrying only one leg can be paired against the other's
       # most recent print — see step/2's own :spread clause.
       y: nil,
       y_at: nil,
       x: nil,
       x_at: nil,
       spread_history: [],
       welford: WelfordAcc.new()
     }}
  end

  ## -----------------------------------------------------------------------
  ## step/2
  ## -----------------------------------------------------------------------

  @doc """
  One tick through `spec`'s kind: `(state, tick) -> {new_state, value |
  :warming_up}`. `spec` supplies the kind's own `params`/`window_ms` on
  every call rather than being baked into `state` at `init/1` time — cheap
  (a spec is plain data) and it keeps `state` containing only what
  actually accumulates across ticks, mirroring how every `TradingCore.Signals`
  function already takes its own tuning via `opts` on every call rather
  than storing it.
  """
  @spec step(Spec.t(), state(), tick()) :: {state(), value() | :warming_up}

  def step(%Spec{kind: :plain}, state, %{value: value}) do
    {state, to_decimal(value)}
  end

  def step(%Spec{kind: :momentum} = spec, state, %{at: now, value: value}) do
    opts = window_opts(spec)
    {prices, result} = Signals.momentum(state.prices, value, now, opts)
    {%{state | prices: prices}, warm(result)}
  end

  def step(%Spec{kind: :derivative} = spec, state, %{at: now, value: value}) do
    opts = window_opts(spec)
    {history, result} = Signals.derivative(state.history, value, now, opts)
    {%{state | history: history}, warm(result)}
  end

  def step(%Spec{kind: :second_derivative} = spec, state, %{at: now, value: value}) do
    opts = window_opts(spec)
    {history, result} = Signals.derivative(state.history, value, now, opts)
    {%{state | history: history}, warm(result)}
  end

  def step(%Spec{kind: :wavelet}, state, %{value: value}) do
    {window, result} = Signals.wavelet(state.window, value)
    {%{state | window: window}, warm(result)}
  end

  def step(%Spec{kind: :volume} = spec, state, %{at: now, value: raw_reading}) do
    session_reset = Map.get(spec.params, "session_reset")
    state = maybe_reset_volume_session(state, now, session_reset)

    reading = to_decimal(raw_reading)

    delta =
      case state.last_reading do
        nil -> nil
        last -> non_negative_delta(reading, last)
      end

    cum_volume =
      case delta do
        nil -> state.cum_volume
        d -> Decimal.add(state.cum_volume, d)
      end

    new_state = %{state | cum_volume: cum_volume, last_reading: reading}

    case delta do
      nil -> {new_state, :warming_up}
      _ -> {new_state, cum_volume}
    end
  end

  def step(%Spec{kind: :vwap} = spec, state, %{at: now} = tick) do
    session_reset = Map.get(spec.params, "session_reset")
    state = maybe_reset_vwap_session(state, now, session_reset)

    price = if tick[:value], do: to_decimal(tick[:value]), else: state.last_price
    delta = if tick[:volume], do: to_decimal(tick[:volume]), else: nil

    cum_pv = Signals.fold_price_weighted_delta(state.cum_pv, price, delta)

    cum_volume =
      case delta do
        nil -> state.cum_volume
        d -> Decimal.add(state.cum_volume, d)
      end

    new_state = %{
      state
      | cum_pv: cum_pv,
        cum_volume: cum_volume,
        last_price: price || state.last_price
    }

    case Signals.vwap(cum_pv, cum_volume) do
      nil -> {new_state, :warming_up}
      value -> {new_state, value}
    end
  end

  def step(%Spec{kind: :donchian} = spec, state, %{at: now, value: value}) do
    opts = window_opts(spec)
    {prices, result} = Signals.donchian(state.prices, value, now, opts)
    {%{state | prices: prices}, warm(result)}
  end

  def step(%Spec{kind: :rolling_volume} = spec, state, %{at: now, value: raw_reading}) do
    opts = window_opts(spec)
    window_ms = Keyword.fetch!(opts, :window_ms)
    max_history_samples = Keyword.get(opts, :max_history_samples, 500)
    reading = to_decimal(raw_reading)

    readings =
      [{now, reading} | state.readings]
      |> Enum.filter(fn {at, _r} ->
        DateTime.compare(at, DateTime.add(now, -window_ms, :millisecond)) != :lt
      end)
      |> Enum.take(max_history_samples)

    new_state = %{state | readings: readings}

    case windowed_volume(readings) do
      nil -> {new_state, :warming_up}
      value -> {new_state, value}
    end
  end

  def step(%Spec{kind: :self_zscore} = spec, state, %{at: now, value: value}) do
    opts = window_opts(spec)

    {history, welford, result} =
      Signals.self_zscore(state.history, state.welford, value, now, opts)

    {%{state | history: history, welford: welford}, warm(result)}
  end

  def step(%Spec{kind: :percent_deviation}, state, tick) do
    state = merge_dual_parent(state, tick)

    case ready_dual(state) do
      false -> {state, :warming_up}
      true -> {state, warm(Signals.percent_deviation(state.value, state.reference))}
    end
  end

  def step(%Spec{kind: :ratio}, state, tick) do
    state = merge_dual_parent(state, tick)

    case ready_dual(state) do
      false -> {state, :warming_up}
      true -> {state, warm(Signals.ratio(state.value, state.reference))}
    end
  end

  def step(%Spec{kind: :zscore} = spec, state, tick) do
    state = merge_dual_parent(state, tick)

    case ready_dual(state) do
      false ->
        {state, :warming_up}

      true ->
        now = Map.fetch!(tick, :at)
        session_reset = Map.get(spec.params, "session_reset")
        state = maybe_reset_zscore_session(state, now, session_reset)
        opts = window_opts(spec)

        {history, welford, result} =
          Signals.spread_zscore(
            state.history,
            state.welford,
            state.value,
            state.reference,
            now,
            opts
          )

        {%{state | history: history, welford: welford}, warm(result)}
    end
  end

  def step(%Spec{kind: :regime} = spec, state, tick) do
    state =
      state
      |> maybe_put(:direction, Map.get(tick, :value))
      |> maybe_put(:gate, Map.get(tick, :reference))

    case state.direction != nil and state.gate != nil do
      false ->
        {state, :warming_up}

      true ->
        tick_deadband = to_decimal(Map.get(spec.params, "tick_deadband", 300))
        vix_gate_zscore = to_decimal(Map.get(spec.params, "vix_gate_zscore", Decimal.new("1.5")))
        value = Signals.regime(state.direction, state.gate, tick_deadband, vix_gate_zscore)
        {state, value}
    end
  end

  # :spread's tick carries raw prices (:value is the Y leg, :reference the
  # X leg — see Spec's own moduledoc, "Why :spread is a base kind").
  # beta_mode dispatch mirrors TradingCore.Signals' own one-function-per-
  # mode split (rolling_ols_beta/4, kalman_beta/4) rather than branching
  # inside one shared function.
  #
  # A tick may carry one leg or both. Two independent price feeds never
  # print simultaneously — SPY ticks, then QQQ ticks — so requiring both
  # on one tick would push last-known-of-each bookkeeping onto every
  # consumer, each reimplementing it slightly differently. Worse, it would
  # make the *pairing policy* a caller concern: which Y is matched against
  # which X decides what distribution the spread's z-score is measuring,
  # so a live path holding legs in a GenServer and a replay path feeding
  # pre-joined rows would be computing genuinely different signals. Since
  # "replay is provably the same computation" is this module's whole
  # reason for existing, the merge belongs here. Same fix, same reasoning,
  # as the dual-parent kinds' own merge_dual_parent/2.
  #
  # Unlike those kinds, though, staleness matters: a percent_deviation
  # against a reference that last moved an hour ago is merely stale, but a
  # pairs spread pairing a fresh Y against an hour-old X reports a
  # relationship that never held at any instant. `params`
  # "max_leg_staleness_ms" bounds that — when set, the legs must have
  # printed within that many milliseconds of each other or the tick yields
  # :warming_up rather than a fabricated pair. Unset (the default) means
  # unbounded, preserving exactly the behavior a caller already feeding
  # joined ticks sees today.
  def step(%Spec{kind: :spread} = spec, state, %{at: now} = tick) do
    state = merge_spread_legs(state, tick, now)

    case spread_legs_ready(state, spec, now) do
      {:ok, y, x} -> compute_spread(spec, state, y, x, now)
      :error -> {state, :warming_up}
    end
  end

  defp compute_spread(spec, state, y, x, now) do
    log_x = x |> to_decimal() |> Decimal.to_float() |> :math.log() |> Decimal.from_float()
    log_y = y |> to_decimal() |> Decimal.to_float() |> :math.log() |> Decimal.from_float()

    beta_opts = beta_window_opts(spec)

    {beta_state, beta_alpha} =
      case state.beta_mode do
        "static" ->
          {state.beta_state, state.beta_state}

        "rolling_ols" ->
          {history, result} =
            Signals.rolling_ols_beta(state.beta_state.history, {log_x, log_y}, now, beta_opts)

          {%{history: history}, result}

        "kalman" ->
          sample_count = state.beta_state.sample_count

          {filter_state, result} =
            Signals.kalman_beta(state.beta_state.filter, {log_x, log_y}, sample_count, beta_opts)

          {%{filter: filter_state, sample_count: sample_count + 1}, result}
      end

    case beta_alpha do
      nil ->
        {%{state | beta_state: beta_state}, :warming_up}

      {beta, alpha} ->
        opts = window_opts(spec)
        spread = Signals.log_spread(log_x, log_y, beta, alpha, opts)

        {spread_history, welford, zscore} =
          Signals.self_zscore(state.spread_history, state.welford, spread, now, opts)

        new_state = %{
          state
          | beta_state: beta_state,
            beta: beta,
            alpha: alpha,
            spread_history: spread_history,
            welford: welford
        }

        {new_state, warm(zscore)}
    end
  end

  # Stores whichever legs this tick carried, each with its own arrival
  # time, leaving the other leg's last-known value untouched. Mirrors
  # merge_dual_parent/2's "latest of each" semantics, plus the per-leg
  # timestamp spread_legs_ready/3 needs to judge staleness.
  defp merge_spread_legs(state, tick, now) do
    state
    |> put_leg(:y, :y_at, Map.get(tick, :value), now)
    |> put_leg(:x, :x_at, Map.get(tick, :reference), now)
  end

  defp put_leg(state, _key, _at_key, nil, _now), do: state

  defp put_leg(state, key, at_key, value, now) do
    state |> Map.put(key, to_decimal(value)) |> Map.put(at_key, now)
  end

  # Both legs must be known, and — when "max_leg_staleness_ms" is set —
  # must have printed within that window of each other. Unset means
  # unbounded, so a caller already supplying joined ticks is unaffected.
  defp spread_legs_ready(%{y: nil}, _spec, _now), do: :error
  defp spread_legs_ready(%{x: nil}, _spec, _now), do: :error

  defp spread_legs_ready(%{y: y, x: x, y_at: y_at, x_at: x_at}, spec, _now) do
    case Map.get(spec.params, "max_leg_staleness_ms") do
      nil ->
        {:ok, y, x}

      max_ms ->
        if abs(DateTime.diff(y_at, x_at, :millisecond)) <= max_ms do
          {:ok, y, x}
        else
          :error
        end
    end
  end

  @doc """
  Beta, alpha, half-life, and crossing-count for a `:spread` node's current
  `state` — the extra outputs that don't fit `step/2`'s scalar `value()`
  contract (see this module's moduledoc, "`:spread`'s output is a z-score,
  like every other kind"). Callable at any point after `init/1` (before
  warm-up, every field is `nil`/`0` as appropriate); most useful right
  after a `step/2` call, to read off this tick's fit alongside its z-score.

  `half_life`/`crossings` are computed here, on demand, from the same
  `state.spread_history` the z-score step already maintains — not
  precomputed on every `step/2` call — matching the pairs-trading design's
  call for these to be opt-in extra work, paid only by a caller that asks
  for them, rather than unconditional per-tick cost every `:spread` node
  pays whether or not anything downstream reads them.

  Returns `nil` for `:beta`/`:alpha` before the beta estimator has produced
  its first fit (`static` mode: never, once `spec.params` supplies
  `"beta"`; `rolling_ols`/`kalman`: until their own minimum-sample rule is
  met — see `TradingCore.Signals.rolling_ols_beta/4`/`kalman_beta/4`).
  `:half_life` is `nil` under the same "not mean-reverting" / "not enough
  samples" conditions `TradingCore.Signals.spread_half_life/1` documents.
  `:crossings` is `0`, never `nil`, before the spread window has 2 samples.
  """
  @spec spread_extras(state()) :: %{
          beta: Decimal.t() | nil,
          alpha: Decimal.t() | nil,
          half_life: float() | nil,
          crossings: non_neg_integer()
        }
  def spread_extras(%{beta: beta, alpha: alpha, spread_history: history, welford: welford}) do
    %{
      beta: beta,
      alpha: alpha,
      half_life: Signals.spread_half_life(history),
      crossings: Signals.spread_crossings(history, welford.mean)
    }
  end

  ## -----------------------------------------------------------------------
  ## replay/3
  ## -----------------------------------------------------------------------

  @doc """
  Runs `tick_series` (a list of ticks for `spec`'s own base symbol, oldest
  first) through `spec`'s entire DAG in one call, returning the value
  series `spec` itself emits — one entry per input tick, each either a
  `value()` or `:warming_up`.

  Resolves `spec` (and every `:parent`/`:reference` reachable from it) in
  topological order — the base kind(s) at the leaves first, each derived
  node only once its own parent(s) have already been evaluated for the
  tick in question — so a node with two derived descendants (e.g. a
  `:wavelet` feeding both a `:derivative` and, via that derivative, a
  `:second_derivative`) is computed exactly once per tick, not once per
  path to it, same as a live deployment's process-per-node topology
  naturally gives for free (each `TradingSignal.Signals.Process` computes
  once and broadcasts to every subscriber).

  Every base-kind node in the DAG needs its own tick stream — `ticks`
  accepts either a bare `[tick()]` list (the common case: one symbol's
  ticks, fed to every base-kind node in the tree, e.g. a `:wavelet` ->
  `:derivative` -> `:second_derivative` chain all ultimately reading one
  underlying price series) or a `%{Spec.t() => [tick()]}` map keyed by
  base-kind node, for a DAG whose base kinds are genuinely different
  symbols/feeds (e.g. `:regime`'s direction parent reading a TICK series
  while its gate parent's `:self_zscore` wraps a VIX series — two
  unrelated tick streams feeding one tree). Every timestamp across every
  supplied series is merged into one sorted timeline; at each timeline
  instant, a base-kind node only receives a real tick if *its own* series
  has an entry at that exact `:at` — otherwise it's treated the same as
  "no message this instant" (mirrors a live signal simply not receiving a
  PubSub broadcast that tick).

  Every derived node instead receives the synthesized `%{at:, value:}` (or
  `%{at:, value:, reference:}`) tick built from its own parent's (and, for
  a dual-parent kind, its reference's) emitted value at that same timeline
  instant. A single-parent kind (`derivative`, `second_derivative`,
  `wavelet`, `self_zscore`) is only stepped when its one parent actually
  emitted (a real value, not `:warming_up`) at this instant — same as a
  live wrapping signal, which only recomputes on an actual parent
  broadcast. A dual-parent kind (`percent_deviation`, `zscore`, `ratio`,
  `regime`) is stepped on *any* instant either side has something new,
  using the other side's last-known value for whichever side stayed
  silent — the "latest of each" rule `TradingSignal.Signals.Deviation`/
  `Regime` already implement live (see either module's own moduledoc) —
  except it is never stepped at all on an instant where *neither* side
  has anything new (a base-kind node from an unrelated series ticking
  alone shouldn't spuriously recompute a dual-parent node that has
  nothing new from either of its own two inputs).

  `opts`:

    * `:only` — when given, a `Spec.t()` (normally `spec` itself, or a
      node from `Spec.nodes(spec)`) whose value series alone is returned,
      instead of the whole map keyed by every node. Convenience for the
      overwhelmingly common "I just want this one series" case. The
      returned list has one entry per node's own tick — an instant where
      that particular node never actually stepped (an unrelated base
      series ticking, or a still-`:warming_up` parent) is omitted, not
      padded with a placeholder, so this is naturally shorter than the
      merged timeline for anything but a single-series replay.

  Returns `%{Spec.t() => [value() | :warming_up]}` (every node's own
  series, keyed by the node itself) unless `:only` narrows it to a single
  `[value() | :warming_up]` list.
  """
  @spec replay(Spec.t(), [tick()] | %{Spec.t() => [tick()]}, keyword()) ::
          %{Spec.t() => [value() | :warming_up]} | [value() | :warming_up]
  def replay(%Spec{} = spec, ticks, opts \\ []) do
    order = topological_order(spec)
    base_nodes = Enum.filter(order, &Spec.base_kind?(&1.kind))
    ticks_by_base = normalize_ticks(ticks, base_nodes)

    timeline = merged_timeline(ticks_by_base)
    ticks_by_base_and_at = index_by_at(ticks_by_base)

    initial_states = Map.new(order, fn node -> {node, init!(node)} end)

    {_final_states, series_by_node} =
      Enum.reduce(timeline, {initial_states, Map.new(order, &{&1, []})}, fn at,
                                                                            {states, series} ->
        step_all(order, at, ticks_by_base_and_at, states, series)
      end)

    series_by_node = Map.new(series_by_node, fn {node, rev} -> {node, Enum.reverse(rev)} end)

    case Keyword.fetch(opts, :only) do
      {:ok, node} -> Map.fetch!(series_by_node, node)
      :error -> series_by_node
    end
  end

  # A bare list is the common single-series case: every base-kind node in
  # the tree reads the same ticks. A map lets each base-kind node declare
  # its own series (see replay/3's own moduledoc).
  defp normalize_ticks(ticks, base_nodes) when is_list(ticks) do
    Map.new(base_nodes, &{&1, ticks})
  end

  defp normalize_ticks(ticks, base_nodes) when is_map(ticks) do
    Map.new(base_nodes, fn node -> {node, Map.get(ticks, node, [])} end)
  end

  defp merged_timeline(ticks_by_base) do
    ticks_by_base
    |> Map.values()
    |> List.flatten()
    |> Enum.map(& &1.at)
    |> Enum.uniq()
    |> Enum.sort({:asc, DateTime})
  end

  defp index_by_at(ticks_by_base) do
    Map.new(ticks_by_base, fn {node, ticks} ->
      {node, Map.new(ticks, &{&1.at, &1})}
    end)
  end

  defp init!(spec) do
    {:ok, state} = init(spec)
    state
  end

  defp step_all(order, at, ticks_by_base_and_at, states, series) do
    Enum.reduce(order, {states, series}, fn node, {states, series} ->
      state = Map.fetch!(states, node)

      case tick_for(node, at, ticks_by_base_and_at, series) do
        # No real input for this node at this timeline instant — either a
        # base-kind node whose own series has nothing at `at` (an
        # unrelated series' tick), a single-parent kind whose one parent
        # didn't emit here, or a dual-parent kind where neither side has
        # anything new. Same as "no message this instant" live: state is
        # left untouched and the node stays :warming_up for this index.
        :not_ready ->
          {states, Map.update!(series, node, &[:warming_up | &1])}

        tick ->
          {new_state, value} = step(node, state, tick)

          {
            Map.put(states, node, new_state),
            Map.update!(series, node, &[value | &1])
          }
      end
    end)
  end

  # Base kinds only get a real tick when their own series has one at this
  # exact timeline instant. :spread is base-like (see Spec's own moduledoc,
  # "Why :spread is a base kind") but its tick carries two raw prices
  # (:value for its Y leg, :reference for its X leg) rather than one — the
  # caller building `ticks`/`ticks_by_base_and_at` supplies that shape for
  # a :spread node directly; this clause forwards it unmodified same as
  # every other base kind's single-price tick.
  defp tick_for(%Spec{kind: kind} = node, at, ticks_by_base_and_at, _series)
       when kind in [:plain, :volume, :vwap, :donchian, :rolling_volume, :spread] do
    case Map.fetch(ticks_by_base_and_at, node) do
      {:ok, %{^at => tick}} -> tick
      _ -> :not_ready
    end
  end

  # Single-parent kinds consume the synthesized tick built from their
  # parent's own just-computed emission at this same instant — the
  # "value is whatever the parent signal broadcasts" wiring
  # Derivative/Wavelet/SelfZscore do live via PubSub, reproduced here as
  # a plain function of the already-computed series instead. Not ready
  # unless the parent actually emitted a real value here.
  defp tick_for(%Spec{kind: kind, parent: parent}, at, _ticks_by_base_and_at, series)
       when kind in [:derivative, :second_derivative, :wavelet, :self_zscore] do
    case List.first(Map.fetch!(series, parent)) do
      :warming_up -> :not_ready
      parent_value -> %{at: at, value: parent_value}
    end
  end

  # Unlike a single-parent kind, a dual-parent kind's live counterpart
  # (Deviation/Regime) recomputes on a tick from *either* side alone,
  # using the other side's last-known value — see either module's own
  # moduledoc, "latest of each." Stepped whenever *either* side emitted a
  # real value this instant; a side that stayed silent (or is still
  # :warming_up) is passed through as `nil`, which step/2's
  # merge_dual_parent/2 already treats as "no new reading this tick, keep
  # whatever this side last held." Not ready at all only when *neither*
  # side has anything new this instant.
  defp tick_for(
         %Spec{kind: kind, parent: parent, reference: reference},
         at,
         _ticks_by_base_and_at,
         series
       )
       when kind in [:percent_deviation, :zscore, :ratio, :regime] do
    parent_value = value_or_nil(List.first(Map.fetch!(series, parent)))
    reference_value = value_or_nil(List.first(Map.fetch!(series, reference)))

    if parent_value == nil and reference_value == nil do
      :not_ready
    else
      %{at: at, value: parent_value, reference: reference_value}
    end
  end

  defp value_or_nil(:warming_up), do: nil
  defp value_or_nil(other), do: other

  # Kahn's algorithm over Spec's :parent/:reference edges — parents (and
  # references) always precede the node that depends on them, which is
  # exactly what step_all/4 needs to feed each dual/single-parent kind its
  # inputs' *already-computed-this-tick* values rather than last tick's.
  defp topological_order(spec) do
    all_nodes = Spec.nodes(spec) |> Enum.uniq()

    Enum.each(all_nodes, &validate_node!/1)

    edges =
      for node <- all_nodes,
          dep <- [node.parent, node.reference],
          dep != nil,
          do: {dep, node}

    dependents = Enum.group_by(edges, fn {dep, _node} -> dep end, fn {_dep, node} -> node end)

    indegree =
      Map.new(all_nodes, fn node ->
        count = Enum.count(edges, fn {_dep, n} -> n == node end)
        {node, count}
      end)

    kahn_sort(all_nodes, dependents, indegree, [])
  end

  # Mirrors TradingSignal.Signals.SignalDefinition.validate_parent_for_kind/1's
  # own shape check, one layer up from the database: a single/dual-parent
  # kind with a missing parent/reference is not a valid computation — left
  # unchecked, it would silently resolve to an empty tick series (no base
  # node reaches it) rather than a clear error, exactly the kind of
  # "quietly wrong, not obviously broken" failure this library exists to
  # rule out.
  defp validate_node!(%Spec{kind: kind, parent: nil})
       when kind in [:derivative, :second_derivative, :wavelet, :self_zscore] do
    raise ArgumentError, "#{inspect(kind)} spec requires a :parent"
  end

  defp validate_node!(%Spec{kind: kind, parent: parent, reference: reference})
       when kind in [:percent_deviation, :zscore, :ratio, :regime] do
    if parent == nil or reference == nil do
      raise ArgumentError, "#{inspect(kind)} spec requires both :parent and :reference"
    end
  end

  defp validate_node!(%Spec{kind: :spread, symbol: symbol, reference_symbol: reference_symbol}) do
    if symbol == nil or reference_symbol == nil do
      raise ArgumentError, ":spread spec requires both :symbol and :reference_symbol"
    end
  end

  defp validate_node!(_spec), do: :ok

  defp kahn_sort([], _dependents, _indegree, acc), do: Enum.reverse(acc)

  defp kahn_sort(remaining, dependents, indegree, acc) do
    {ready, rest} = Enum.split_with(remaining, fn node -> Map.fetch!(indegree, node) == 0 end)

    if ready == [] do
      raise ArgumentError, "TradingCore.Signal.Spec tree contains a cycle"
    end

    indegree =
      Enum.reduce(ready, indegree, fn node, indegree ->
        Enum.reduce(Map.get(dependents, node, []), indegree, fn dependent, indegree ->
          Map.update!(indegree, dependent, &(&1 - 1))
        end)
      end)

    kahn_sort(rest, dependents, indegree, Enum.reverse(ready) ++ acc)
  end

  ## -----------------------------------------------------------------------
  ## Shared helpers
  ## -----------------------------------------------------------------------

  defp window_opts(%Spec{window_ms: nil, params: params}) do
    []
    |> maybe_put_precision(params)
    |> maybe_put_max_history_samples(params)
  end

  defp window_opts(%Spec{window_ms: window_ms, params: params}) do
    [window_ms: window_ms]
    |> maybe_put_precision(params)
    |> maybe_put_max_history_samples(params)
  end

  defp maybe_put_precision(opts, params) do
    case Map.get(params, "precision") do
      nil -> opts
      precision -> Keyword.put(opts, :precision, precision)
    end
  end

  defp maybe_put_max_history_samples(opts, params) do
    case Map.get(params, "max_history_samples") do
      nil -> opts
      max -> Keyword.put(opts, :max_history_samples, max)
    end
  end

  # :spread's beta-estimation window is deliberately independent of its
  # mu/sigma window (window_opts/1, used for the z-score step) — see
  # Spec's own moduledoc discussion of the two-window design and this
  # kind's step/2 clause. Resolved the same way window_opts/1 resolves its
  # own window: a precomputed millisecond value on params, never a
  # duration string (see Spec's "Why window_ms is precomputed" section —
  # the same reasoning applies to this second window).
  defp beta_window_opts(%Spec{params: params}) do
    []
    |> maybe_put_beta_window_ms(params)
    |> maybe_put_precision(params)
    |> maybe_put_max_history_samples(params)
  end

  defp maybe_put_beta_window_ms(opts, params) do
    case Map.get(params, "beta_window_ms") do
      nil -> opts
      window_ms -> Keyword.put(opts, :window_ms, window_ms)
    end
  end

  # `static` beta_mode: beta/alpha are supplied once, up front, via
  # params — never re-estimated — so this reads them at init/1 time and
  # step/2's "static" branch just echoes them back every tick, same
  # {beta, alpha} shape rolling_ols_beta/4 and kalman_beta/4 return once
  # warmed up. Defaults alpha to 0 (a pure ratio-style spread) if the
  # caller only cares about beta and doesn't supply an intercept.
  defp static_beta_alpha(params) do
    beta = Map.fetch!(params, "beta") |> to_decimal()
    alpha = params |> Map.get("alpha", 0) |> to_decimal()
    {beta, alpha}
  end

  defp warm(nil), do: :warming_up
  defp warm(value), do: value

  defp merge_dual_parent(state, tick) do
    state
    |> maybe_put(:value, Map.get(tick, :value))
    |> maybe_put(:reference, Map.get(tick, :reference))
  end

  defp maybe_put(state, _key, nil), do: state
  defp maybe_put(state, key, value), do: Map.put(state, key, to_decimal(value))

  defp ready_dual(%{value: v, reference: r}), do: v != nil and r != nil

  defp non_negative_delta(reading, last) do
    delta = Decimal.sub(reading, last)
    if Decimal.compare(delta, 0) == :lt, do: nil, else: delta
  end

  defp windowed_volume(readings) when length(readings) < 2, do: nil

  defp windowed_volume(readings) do
    {_newest_at, newest} = List.first(readings)
    {_oldest_at, oldest} = List.last(readings)
    delta = Decimal.sub(newest, oldest)
    if Decimal.compare(delta, 0) == :lt, do: Decimal.new(0), else: delta
  end

  defp maybe_reset_vwap_session(state, _now, nil), do: state

  defp maybe_reset_vwap_session(state, now, session_reset) when is_function(session_reset, 1) do
    session = session_reset.(now)

    if state.session != nil and session != state.session do
      %{state | cum_pv: Decimal.new(0), cum_volume: Decimal.new(0), session: session}
    else
      %{state | session: session}
    end
  end

  # Same injected-function shape as maybe_reset_vwap_session/3 above (see
  # step/2's :vwap clause and this module's own "Session boundaries"
  # moduledoc section) but resets :volume's own state shape — cum_volume
  # AND last_reading both back to their init/1 values, mirroring
  # TradingSignal.Signals.CumulativeVolume.reset_if_new_session/1 exactly:
  # last_reading: nil specifically (not just cum_volume: 0) is required so
  # the very next tick after a reset is treated as "no prior reading to
  # diff against yet" (this step/2 clause's own `case state.last_reading do
  # nil -> nil` branch), not as a delta against a stale pre-reset reading
  # that would otherwise register as either a huge bogus volume spike or,
  # worse, a negative delta silently discarded as noise.
  defp maybe_reset_volume_session(state, _now, nil), do: state

  defp maybe_reset_volume_session(state, now, session_reset) when is_function(session_reset, 1) do
    session = session_reset.(now)

    if state.session != nil and session != state.session do
      %{state | cum_volume: Decimal.new(0), last_reading: nil, session: session}
    else
      %{state | session: session}
    end
  end

  # Same injected-function shape as the two helpers above, clearing
  # :zscore's own spread window rather than a running total.
  #
  # Why a spread z-score wants this at all: a :zscore whose reference is a
  # session-resetting kind (canonically a `:vwap`) measures value-minus-
  # reference, and that reference jumps discontinuously the instant its
  # session rolls — the new session's VWAP restarts from its first tick
  # rather than continuing yesterday's cumulative average. Spread samples
  # taken either side of that jump are not observations of the same
  # quantity, so a window straddling it produces a mean and standard
  # deviation describing a distribution that never existed, and a z-score
  # against it is meaningless in a way no window length can fix. Clearing
  # both `history` and `welford` restarts the distribution with the new
  # session, at the cost of a fresh warm-up (`spread_zscore/6` returns
  # nil, hence `:warming_up`, until the rebuilt Welford accumulator has
  # enough samples for a standard deviation).
  #
  # Opt-in: with no "session_reset" in params this is a no-op, so an
  # existing spec's behavior is unchanged until it asks for this. Unlike
  # :vwap/:volume — where a missing session_reset means a total that grows
  # without bound and is plainly wrong — a spread window straddling a
  # session boundary is merely *stale*, self-healing once the window
  # slides past the discontinuity, so defaulting this on would be a live
  # change to every existing :zscore for a problem that partially fixes
  # itself.
  #
  # The stronger reason to keep it opt-in is semantic, not just
  # change-aversion: **turning this on produces a different signal, not a
  # corrected one.** Around a session open, a reset-enabled :zscore
  # reports `:warming_up` exactly where the straddling version reports a
  # number — the reset empties `history`, so the next tick has `count < 2`,
  # `Signals.zscore/2` returns nil, and `warm/1` maps that to
  # `:warming_up`. Values recorded before and after the switch are
  # therefore not comparable: a consumer holding history across the change
  # has to re-read the old values under the new meaning rather than assume
  # a continuous series. Anything storing or scoring this signal's output
  # (a strategy's condition history, a rating computed over closed runs)
  # wants to know the date this was enabled for a given spec, the same way
  # it would for a window change.
  defp maybe_reset_zscore_session(state, _now, nil), do: state

  defp maybe_reset_zscore_session(state, now, session_reset) when is_function(session_reset, 1) do
    session = session_reset.(now)

    if state.session != nil and session != state.session do
      %{state | history: [], welford: WelfordAcc.new(), session: session}
    else
      %{state | session: session}
    end
  end

  defp to_decimal(nil), do: nil
  defp to_decimal(%Decimal{} = value), do: value
  defp to_decimal(value) when is_float(value), do: Decimal.from_float(value)
  defp to_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp to_decimal(value) when is_binary(value), do: Decimal.new(value)
end
