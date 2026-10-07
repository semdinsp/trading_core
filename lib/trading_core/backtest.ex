defmodule TradingCore.Backtest do
  @moduledoc """
  Pure historical replay engine: walks a bar series for one or more
  symbols, replays a strategy's referenced signals through
  `TradingCore.Signals`, evaluates entry/exit via `TradingCore.RuleEngine`,
  computes stop/target via `TradingCore.RiskControls`, applies
  ratchet/trailing exits via `TradingCore.ExitStrategy`, sizes positions
  via `TradingCore.PositionSizing`, and returns a list of simulated closed
  runs in the field shape `TradingSystem.Trading.PerformanceMetrics`
  already reads (`entry_price`, `exit_price`, `direction`, `pnl`, `qty`,
  `exit_at`, `exit_reason`, plus `entry_at`/`symbol` for display). This
  module does **not** compute PnL aggregates/win-rate/Sharpe/etc itself —
  that's `PerformanceMetrics`'s job, already pure and already usable by
  any caller (`trading_system`, `trading_live`, and in the future
  `trading_backtest`) against whatever list of closed runs it's handed,
  live or replayed. This module's job stops at producing that raw list.

  Composes, unchanged: `TradingCore.Signals` (signal state-transition
  math), `TradingCore.RuleEngine` (`entry`/`exit` rule evaluation),
  `TradingCore.RiskControls` (stop/target levels), `TradingCore.ExitStrategy`
  (ratchet/trailing), `TradingCore.PositionSizing` (order quantity). See
  each of those modules' own moduledocs — nothing about their contracts
  changes here; this module is purely orchestration plus the
  backtest-specific glue those modules can't provide on their own (a
  `signal_specs` -> `Signals` function dispatch layer, since there's no
  live signal catalog to query in a backtest, and a trailing-volatility
  estimator for `"volatility_target"` sizing, since there's no live
  `daily_vol` RPC available during a replay).

  ## Public API

      TradingCore.Backtest.run(strategy, bars_by_symbol, opts)

  - `strategy` — a plain map with the same keys `StrategyVersion`/a live
    strategy record already carries for this data (so one engine serves
    both `trading_system` and `trading_live` callers with no per-caller
    translation layer):
    - `"rules"` — `%{"entry" => rule_tree, "exit" => rule_tree | nil}`,
      the exact shape `TradingCore.RuleEngine.evaluate/2` expects.
    - `"direction"` — `"long"` or `"short"`.
    - `"params"` — may contain `"risk_controls"` (see
      `TradingCore.RiskControls.levels/3`) and `"exit_strategy"` (see
      `TradingCore.ExitStrategy.check/5`); either/both may be absent.
    - `"position_sizing"` — the config `TradingCore.PositionSizing.calculate_qty/2`
      expects, e.g. `%{"method" => "fixed_qty", "qty" => 10}`.
  - `bars_by_symbol` — `%{"AAPL" => [bar, ...], ...}`, one chronologically
    ordered list per symbol. A bar is
    `%{ts: DateTime.t(), open:, high:, low:, close:, volume: Decimal.t()}`.
  - `opts` (keyword list):
    - `:signal_specs` (required if `rules` references any signal) — see
      "Signal specs" below.
    - `:literal_series` — `%{"signal_name" => [{DateTime.t(), Decimal.t()}, ...]}`,
      chronological, for a `:series`-kind signal spec (e.g. VIX) not
      derivable from `bars_by_symbol` itself. Optional; defaults to `%{}`.
    - `:volatility_window` — number of trailing **daily** closes used to
      estimate `daily_vol` for `"volatility_target"` sizing (default
      `20`); intraday bars are collapsed to one close per trading day
      first (see `estimate_daily_vol/3`). Ignored entirely if
      `position_sizing["method"] != "volatility_target"`.
    - `:sizing_vol` — the `daily_vol` estimator for `"volatility_target"`
      sizing: `:stdev` (default; standard deviation of the last
      `:volatility_window` daily close-to-close returns) or `:ewma`,
      trading_hub's estimator that live sizing uses
      (`trailing_ewma_vol_sync/4` via trading_system's `DailyVolCache`,
      reproduced by `TradingCore.Volatility.ewma_daily_vol/2`): RiskMetrics
      EWMA of `|ln|` daily returns over `:sizing_vol_lookback_days`
      calendar days (default `14`) with decay `:sizing_vol_lambda`
      (default `0.94`). Both use the same one-close-per-ET-trading-day
      series, with today's close so far at the signal bar. Any other
      value is `{:error, :invalid_sizing_vol}`.
    - `:target_dollar_volatility` — required only when
      `position_sizing["method"] == "volatility_target"`, same meaning as
      `TradingCore.PositionSizing.calculate_qty/2`'s context key.
    - `:intrabar` — `true` to also check stop-loss/take-profit against
      each bar's `high`/`low`, not just its `close` (default `false`). See
      "Exits" below.
    - `:flatten_at` — a `Time` in US/Eastern, e.g. `~T[15:55:00]`, for
      **intraday** bars: no position is held past it. Off (`nil`) by
      default, which leaves results exactly as without it. See
      "End-of-session flatten" below.
    - `:stop_vol_lookback_days` / `:stop_vol_lambda` — the EWMA window
      (calendar days, default `14`) and decay (default `0.94`) for a
      `"volatility_multiple"` risk_controls method. The defaults match the
      hub's `trailing_ewma_vol_sync/4`, which is what the live apps pass;
      change them only to test sensitivity. Each run reports the
      `stop_method` actually applied and the `stop_daily_vol` used, since
      an entry with too little history falls back to `percent_of_entry`.
    - `:round_numbers` — `TradingCore.RoundNumbers.adjust/4` options
      (e.g. `[stop_zone: :near]` or `[stop_zone: :far, buffer_vol_frac:
      0.2]`) to move both levels off round numbers at entry. Off when
      absent. `:daily_vol`, `:price` and `:entry` default to the entry's
      EWMA vol and entry price; with no vol history, levels are only
      tick-snapped.

  ## Exits

  On every bar with an open position, stop-loss and take-profit are
  checked **first and unconditionally**; a non-empty custom exit rule is
  only consulted when neither was hit. This matches the live order in
  `trading_system`'s `PositionExitCheck` and `trading_live`'s
  `StrategyStockMonitor`. (Before 2026-09-26 the backtest checked SL/TP
  only *inside* a true custom exit rule, so a strategy whose exit rule
  stayed false never stopped out here — backtests of such strategies from
  before then overstate their results.)

  By default the check uses the bar's `close` and the exit fills at the
  next bar's `open`, like any other signal. With `intrabar: true`, the
  bar's `low`/`high` are checked against the levels as they stood when the
  bar opened — before any `exit_strategy` ratchet moves them on this bar's
  close, so the close never informs a check on prices that came before it.
  An intrabar hit fills on that same bar at the level itself, or at the
  bar's `open` if it opened already through the level (a gap). When a bar
  touches both levels, the order inside the bar is unknown and the stop is
  assumed to have come first (the conservative reading). Close-based
  checks and the custom exit rule still run afterwards for a bar with no
  intrabar hit.

  **`exit_strategy` within the bar** (`intrabar: true`). Live applies the
  ratchet/trail on every tick *before* checking the levels, so the tick
  that reaches a ratchet trigger clears the take-profit before it can be
  hit. The backtest reproduces that order on each bar:

    1. The stop as it stood at the bar's open is checked against the
       adverse extreme (low for a long, high for a short) first, as above.
    2. `TradingCore.ExitStrategy.check/5` runs against the favourable
       extreme (high for a long, low for a short).
       - **Ratchet:** if it fires within the bar, the take-profit is
         treated as reached first only when the trigger lies beyond it
         (the ratchet would not fire at the take-profit price itself);
         then the bar is a `"target_hit"`. Otherwise the trigger came
         first or at the same price, as live sees it: the take-profit is
         cleared and the stop moves to its locked level, with no
         `"target_hit"` on that bar.
       - **Trailing:** the trail is updated from the favourable extreme
         (live sees every tick, not only the close). A trail never clears
         the take-profit, so the take-profit check is unchanged.
    3. A stop moved within the bar only takes effect from that bar's
       close check onwards. The bar is never assumed to have hit the new
       stop after reaching the trigger, since the order of prices inside
       the bar is unknown.

  (Before 2026-10-07 the ratchet ran only on the close, after the
  intrabar checks, so a ratchet strategy whose trigger sat at or inside
  its take-profit banked the take-profit on every winner where live let
  it run. Intrabar backtests of such strategies from before then
  understate their winners.) With `intrabar: false` the ratchet already
  runs on the close before the close-based level check, which is the
  same order as live at bar resolution.

  ## End-of-session flatten

  With `flatten_at: ~T[15:55:00]`, every bar's time is read in
  America/New_York (so DST is handled) against the US-equities regular
  session from `TradingCore.MarketHours`:

  - **Flatten.** An open position is closed at the close of the first bar
    at or after the cutoff, with `exit_reason: "eod_flatten"`. An
    `intrabar: true` stop or target hit on that same bar still wins,
    since it happened before the close. The cutoff keeps the same
    distance before an early close, so 15:55 becomes 12:55 on a 13:00
    half day; a `Time` at or after 16:00 means the close itself.
  - **Safety net.** A position still open on the last bar of a session
    (a data gap skipped the cutoff bar), or on a bar outside any
    session, is flattened at that bar's close the same way, so nothing is
    held overnight. When the data itself ends, its last bar flattens only
    if that bar's minute reaches the cutoff (the data ends on the
    session's final minute bar); data that stops mid-session still closes
    as `"end_of_data"`.
  - **No entries in the window.** An entry fills at the next bar's open,
    so a signal is acted on only when both its bar and the fill bar are
    in the same session, at or after the 09:30 open and before the
    cutoff. Signals in the flatten window, after hours, pre-market or
    across a session boundary are ignored until the next session opens.

  It is meant for intraday bars. Daily bars have timestamps outside the
  session, so with `:flatten_at` set they would never enter.

  Live trading_system closes a version with no `close_after_hours` or
  `time_box_exit_et` when the session actually closes (its 5-minute
  `market_close` sweep), so `~T[15:55:00]` is a slightly earlier,
  deliberate choice rather than an exact copy of live.

  Returns `{:ok, [run]}` where each `run` is a plain map:

      %{
        symbol: "AAPL",
        direction: "long" | "short",
        entry_at: DateTime.t(),
        entry_price: Decimal.t(),
        exit_at: DateTime.t(),
        exit_price: Decimal.t(),
        exit_reason:
          "stopped_out" | "target_hit" | "rule_exit" | "end_of_data" | "eod_flatten",
        stop_method: "percent_of_entry" | "volatility_multiple",
        stop_daily_vol: Decimal.t() | nil,
        entry_stop_loss_price: Decimal.t() | nil,
        entry_take_profit_price: Decimal.t() | nil,
        qty: Decimal.t(),
        pnl: Decimal.t()
      }

  `entry_stop_loss_price`/`entry_take_profit_price` are the levels as set
  when the run opened (after `:round_numbers`), before any
  `exit_strategy` ratchet or trail moved the stop or cleared the target,
  so a caller can compute risk at entry (R) from them.

  `pnl = (exit_price - entry_price) * qty` for `"long"`, inverted for
  `"short"` — same sign convention `TradingSystem.Trading.Workers.CloseRunWorker`'s
  `realized_pnl` already uses, which is what lets
  `TradingSystem.Trading.PerformanceMetrics` consume this list unchanged.

  A run still open when a symbol's bars run out is force-closed at the
  last bar's close with `exit_reason: "end_of_data"` — a backtest has no
  "still open" state to hand back to a caller expecting a finished list,
  unlike a live run which can just stay open indefinitely.

  ## Signal specs: how a named signal maps to a `Signals` function

  A strategy's `rules` reference signals by name (e.g.
  `"massive_spy_derivative"`, `"ibkr_vix_self_zscore"`) — plain strings,
  the same names `TradingCore.RuleEngine.signal_names/1` extracts from a
  rule tree. In live `trading_signal`, "which named signal resolves to
  which computation" is answered by a signal-definition catalog in
  Postgres (kind + parent chain, per `signal_id`). A backtest has no
  catalog to query (no `trading_signal` RPC, no DB row) — so the caller
  must describe that shape explicitly via `opts[:signal_specs]`, one entry
  per name the strategy's rules reference (use
  `TradingCore.RuleEngine.signal_names/1` on both `rules["entry"]` and
  `rules["exit"]` to find out which names those are, minus any
  `run_`-prefixed name — those are supplied by this module itself from
  the run's own state, never from `signal_specs`, see `TradingCore.RuleEngine`'s
  moduledoc on the `run_` prefix convention).

  Each `signal_specs` entry is `%{kind: atom(), scope: :symbol | :global, ...}`
  plus whatever extra keys that `kind` needs:

  - `kind: :price` — the raw bar `close` itself, scoped `:symbol` always
    (there's no "global raw price" — a base price series is inherently
    about one instrument). No extra keys.
  - `kind: :volume` — the raw bar `volume` itself, same shape/scoping
    rules as `kind: :price` (`:symbol`-scoped by default, or `:global` with
    an explicit `symbol:` override for one fixed instrument's volume used
    across a pool). No extra keys, no windowing/accumulation of its own —
    a bar's `volume` field is already that bar's own period total (for a
    `"day"`-timespan bar, the full session's cumulative volume), matching
    what `TradingSignal.Signals.Volume`'s live cumulative-since-session-open
    value means once each trading day closes. See that module's own
    moduledoc, "Cumulative vs. per-bar volume," for why live tick-by-tick
    reconstruction needs session-reset bookkeeping this kind deliberately
    doesn't reproduce — a bars-based replay has no live ticks to
    reconstruct from in the first place, only the bar's own already-final
    `volume` value.
  - `kind: :vwap` — the bar's own `vwap` field, same shape/scoping rules
    as `kind: :price`/`:volume`. Requires the caller's `bars_by_symbol`
    bars to actually carry a `:vwap` key (optional on the `bar()` type —
    see that type's own doc); a bar missing it is treated the same as any
    other kind's "no value yet" case (`nil`, dropped from the snapshot —
    see `build_snapshot/5`). No windowing/accumulation of its own, for the
    same reason `:volume` needs none: Polygon's own flat-file day-aggregate
    already supplies a per-day session-VWAP figure (its own `"vw"` field),
    already parsed into `historical_bars.vwap` by
    `TradingBacktest.PolygonFlatFile.Client` — this kind is a pure
    passthrough of that already-computed value, not a `cum_pv`/`cum_volume`
    reconstruction. `TradingCore.Signals.vwap/2` and
    `fold_price_weighted_delta/3` remain available for a caller that *does*
    need to reconstruct VWAP from raw price/volume (e.g. a `"minute"`-
    timespan replay with no per-bar vwap of its own); this kind is
    specifically for the common case where the data source already did
    that work.
  - `kind: :series` — a literal externally-supplied series (e.g. VIX
    level), looked up in `opts[:literal_series][name]`. Always `scope: :global`
    (a literal series isn't derived from any symbol's own bars). Value at
    each bar is the most recent literal-series entry at or before that
    bar's `ts` (last-observation-carried-forward — a real VIX/breadth feed
    doesn't necessarily tick on the same schedule as the equity bars being
    walked).
  - `kind: :derivative` / `:momentum` / `:wavelet` / `:self_zscore` —
    wraps another named signal via `parent: "other_signal_name"`.
    `:derivative`/`:momentum` additionally accept `window_ms:` (passed to
    `TradingCore.Signals.derivative/4`/`momentum/4`'s `opts`); `:self_zscore`
    likewise. `:derivative`, `:self_zscore` and `:spread_zscore` also take
    `sample_interval_ms:` and `on_cap_bound:` (see "Fixed-interval
    sampling" in `TradingCore.Signals`), and `:derivative` takes
    `min_span_ms:` (see "Derivative minimum span" there). `:wavelet` takes no extra options (fixed window/level, see
    `TradingCore.Signals.wavelet/2`).
  - `kind: :percent_deviation` / `:ratio` — wraps two named signals,
    `value: "signal_a"` and `reference: "signal_b"` (both looked up in the
    same bar's already-computed snapshot — declare the referenced signals
    earlier in `signal_specs` so they're computed first, see "Evaluation
    order" below).
  - `kind: :spread_zscore` — same `value:`/`reference:` shape as
    `:percent_deviation`, plus optional `window_ms:`.
  - `kind: :donchian` — wraps `parent: "other_signal_name"` (typically a
    `:price` spec), requires `window_ms:`.
  - `kind: :regime` — `direction: "signal_a"`, `gate: "signal_b"`, plus
    `tick_deadband:` and `vix_gate_zscore:` (both required — this module
    does not default them, matching `TradingCore.Signals.regime/4` taking
    them as explicit args rather than baking in a default; see that
    function's own doc for what a real `Regime` definition's `params`
    would supply).

  `scope` on a wrapping kind is **inherited from its `parent`/`value`
  chain, not independently declared** — see "Multi-symbol scoping" below
  for why forcing the caller to keep a derived signal's scope consistent
  with its parent by construction, rather than letting them declare a
  contradictory one, is the safer default.

  ### Worked example

      rules = %{
        "entry" => %{
          "all" => [
            %{"signal" => "spy_derivative", "op" => "gt", "value" => 0},
            %{"signal" => "vix_self_zscore", "op" => "lt", "value" => 1.5}
          ]
        },
        "exit" => nil
      }

      signal_specs = %{
        # SPY's own momentum — SPY isn't necessarily in the pool being
        # traded, so this is a :global signal computed off SPY's own bars,
        # supplied via bars_by_symbol["SPY"] like any other symbol's bars
        # (it doesn't need to be a *traded* symbol to supply a bar series).
        "spy_price" => %{kind: :price, scope: :global, symbol: "SPY"},
        "spy_derivative" => %{kind: :derivative, parent: "spy_price", window_ms: :timer.minutes(5)},

        # VIX isn't a tradeable bar series in this workspace at all —
        # supplied as a literal series instead.
        "vix_level" => %{kind: :series, scope: :global},
        "vix_self_zscore" => %{kind: :self_zscore, parent: "vix_level", window_ms: :timer.minutes(30)}
      }

      TradingCore.Backtest.run(strategy, bars_by_symbol,
        signal_specs: signal_specs,
        literal_series: %{"vix_level" => vix_series}
      )

  A `:symbol`-scoped signal (`kind: :price` with no `symbol:` override, or
  anything wrapping one) is computed **independently per symbol being
  walked** — e.g. `%{"AAPL" => [...], "MSFT" => [...]}` each get their own
  fresh `close_price`/`close_derivative` state, since a rule like "this
  symbol's own momentum" is inherently about whichever bar series is
  currently being walked, not a fixed instrument.

  ### `kind: :price`'s `symbol:` key — one instrument's own signal, used
  across a whole pool

  `kind: :price` defaults to the symbol currently being walked (no
  `symbol:` key needed for the common "this instrument's own price" case)
  but accepts an explicit `symbol:` override for the
  `massive_spy_derivative`-style case: a signal that's about ONE specific
  instrument (SPY) regardless of which pool symbol's bars are being
  walked. An explicit `symbol:` override forces `scope: :global` (see
  below) — `bars_by_symbol` must include that symbol's own bar series
  (even if that symbol is never itself traded by this strategy) for its
  `ts`s to align against.

  ## Multi-symbol scoping — the design question this module had to settle

  A strategy backtested against a pool of symbols raises a real question:
  does a referenced signal mean "this symbol's own value" or "one fixed
  instrument's value, shared across every symbol in the pool"? Both are
  real cases in this workspace — `ibkr_vix_self_zscore` is global (same
  value no matter which pool symbol's bars are being walked); a signal
  like `close_derivative` on the pool symbol itself is inherently
  per-symbol; and `massive_spy_derivative` is a THIRD case — global in the
  sense of being the same value regardless of pool, but *derived from
  SPY's own bars specifically*, not a literal external series.

  This module resolves it via `scope`, which every `signal_specs` entry
  carries explicitly (`:symbol`, the default meaning of `kind: :price`
  with no `symbol:` override; or `:global` for `kind: :series`, or for
  `kind: :price` with an explicit `symbol:`):

  - **`:symbol`-scoped** signals get their own independent state
    (history/window/Welford accumulator/whatever that kind's `Signals`
    function threads) **per symbol currently being walked** — walking
    AAPL's bars and MSFT's bars through a `:symbol`-scoped
    `close_derivative` spec computes two unrelated derivative series, one
    per symbol, exactly as if each were backtested alone.
  - **`:global`-scoped** signals are computed **once**, along their own
    designated bar series (`kind: :price, symbol: "SPY"`) or literal
    series (`kind: :series`), entirely independent of the pool — this
    computation happens as its own separate walk before the per-symbol
    walk begins (see "Evaluation order" below), and the resulting
    `{timestamp, value}` series is then looked up (last-observation-
    carried-forward by `ts`) at whatever bar timestamp each pool symbol's
    own walk is currently at.
  - **A wrapping kind's scope is inherited from its parent(s)**, not
    independently settable — `derivative` wrapping a `:global` `kind:
    :price` is itself `:global`; `derivative` wrapping the default
    (implicit-`symbol`) `:price` is `:symbol`-scoped. This is a
    deliberate constraint, not an oversight: letting a caller declare
    `scope: :symbol` on a signal wrapping a `:global` parent (or vice
    versa) would be incoherent — there is no such thing as "MSFT's own
    view of SPY's derivative," there's just SPY's derivative, the same
    number regardless of which pool symbol's rules reference it. Making
    scope a derived property closes off that whole category of
    misconfiguration rather than silently accepting it.

  ## Evaluation order

  `signal_specs` is a plain map — Elixir gives no ordering guarantee over
  a map's keys, so "declare parents before dependents" is not a
  constraint this module relies on; dependency order (a `parent`/`value`+
  `reference`/`direction`+`gate` chain resolved before whatever wraps it)
  is derived automatically, not read off map iteration order:

  1. Every `:global`-scoped signal is computed first, as one independent
     walk over its own designated bar/literal series from start to
     finish. A wrapping `:global` signal's dependencies are resolved
     on-demand and memoized (`fetch_series/5`), so any declaration order
     works, including a dependent appearing before the signal it wraps in
     `signal_specs`'s own (unordered) key enumeration — a circular
     dependency, however, is not detected and will exhaust the call stack;
     don't construct one.
  2. Each symbol in `bars_by_symbol` is then walked independently, bar by
     bar, in chronological order. At each bar, every `:symbol`-scoped
     signal is recomputed in dependency order (a one-time topological sort
     computed once per symbol walk, not per bar — parents before whatever
     wraps them), and every `:global`-scoped signal's already-computed
     series is sampled (last-observation-carried-forward) at that bar's
     `ts`. Together these form the flat snapshot
     `TradingCore.RuleEngine.evaluate/2` compares the strategy's rules
     against.
  3. Symbols are walked independently and their resulting closed runs
     concatenated in `bars_by_symbol`'s own key order — a `:global` signal
     computed in step 1 is genuinely shared (the identical value at a
     given timestamp is sampled into every symbol's snapshot at that
     timestamp), but nothing about one symbol's open/closed position state
     affects another's; this module has no portfolio-level concept (shared
     capital, position limits across symbols) — each symbol trades as if
     it had its own unconstrained account. Flagged here as a real scope
     limitation, not silently glossed over.

  ## Design simplifications (documented, not hidden)

  - **Fill price: next bar's `open`.** Entry and exit both fill at the
    bar *following* the one whose close triggered the condition, not the
    triggering bar's own close. Filling at the same bar's close that just
    satisfied the entry/exit condition is a common backtest shortcut but
    is real look-ahead bias (the strategy "sees" a bar's own close and
    trades at that exact price, something no live system can do — a live
    tick-driven fill happens at whatever price arrives *after* the
    decision, never simultaneously with it). Next-bar-open is the more
    defensible choice and what this module does; the resulting `pnl` is
    therefore not directly comparable trade-for-trade against live
    quarantine PnL (which fills at the actual next live tick, not a
    2-minute-cadence bar's open) but shares the same "decide now, fill
    next" causality. A run whose triggering bar is a series' last bar has
    no next bar to fill at — it's simply never opened/closed on that
    signal (see `walk_symbol/2`'s handling).
  - **Signal replay feeds off bar `close`, not live ticks.** Every
    `TradingCore.Signals` function was designed around a live tick stream
    (`last` price, arbitrarily many updates per minute). A bar-level
    replay has exactly one sample per bar — this module treats each bar's
    `close` as "the tick for that period," which necessarily collapses
    whatever intra-bar tick path a live signal would have actually walked
    into a single point. A signal like `derivative` (slope over a
    5-minute window) will replay coarser and smoother than its live
    counterpart ever was, especially at daily-bar granularity. This is a
    real, structural gap between backtest and live signal values, not
    just a rounding difference — flagged as a known limitation.
  - **`"volatility_target"` sizing's `daily_vol` is estimated, not
    fetched.** Live sizing calls an RPC for the pool's actual daily
    volatility; a backtest has no such RPC. `estimate_daily_vol/2` (below)
    computes a simple realized-volatility estimate — stdev of trailing
    daily close-to-close returns over `opts[:volatility_window]` daily
    closes (default 20) — as a stand-in `daily_vol` input to
    `TradingCore.PositionSizing.calculate_qty/2`. This is a real
    approximation, not an equivalent: the live RPC may use a different
    window length, a different estimator (e.g. EWMA, Parkinson/high-low
    range, an options-implied figure), or a different data source
    entirely, so a backtest's sized `qty` for a `"volatility_target"`
    strategy will not match what the same strategy would have actually
    been sized to live, even given identical prices. `"fixed_qty"`
    strategies are unaffected — no estimation happens for them at all.
  - **No portfolio-level constraints.** See "Evaluation order" point 3
    above — no shared capital, no cross-symbol position limits, no
    max-concurrent-runs cap. Each symbol backtests as if it alone held the
    account.
  - **One open run at a time per symbol.** While a symbol has an open
    run, no new entry is evaluated for that symbol — mirrors
    `trading_system`'s own one-run-per-version-per-symbol-at-a-time
    discipline closely enough to be a reasonable default, though this
    module doesn't enforce anything about *other* symbols or versions.
  """

  alias TradingCore.Intraday.RegularSession

  alias TradingCore.{
    ExitStrategy,
    PositionSizing,
    RiskControls,
    RoundNumbers,
    RuleEngine,
    Signals,
    Volatility
  }

  @type bar :: %{
          required(:ts) => DateTime.t(),
          required(:open) => Decimal.t(),
          required(:high) => Decimal.t(),
          required(:low) => Decimal.t(),
          required(:close) => Decimal.t(),
          required(:volume) => Decimal.t(),
          optional(:vwap) => Decimal.t()
        }
  @type run_result :: %{
          symbol: String.t(),
          direction: String.t(),
          entry_at: DateTime.t(),
          entry_price: Decimal.t(),
          exit_at: DateTime.t(),
          exit_price: Decimal.t(),
          exit_reason: String.t(),
          stop_method: String.t(),
          stop_daily_vol: Decimal.t() | nil,
          entry_stop_loss_price: Decimal.t() | nil,
          entry_take_profit_price: Decimal.t() | nil,
          qty: Decimal.t(),
          pnl: Decimal.t()
        }

  @default_volatility_window 20
  # trading_hub's trailing_ewma_vol_sync/4 defaults, which live
  # volatility_target sizing uses via trading_system's DailyVolCache.
  @hub_vol_lookback_days 14
  @hub_vol_lambda 0.94
  @eastern "America/New_York"
  @regular_close ~T[16:00:00]

  @doc """
  Runs a full backtest. See moduledoc for `strategy`/`bars_by_symbol`/`opts`
  shape. Returns `{:ok, [run_result()]}` on success, or
  `{:error, reason}` if `opts[:signal_specs]` is missing/malformed for a
  signal the rules actually reference, `{:error, :invalid_flatten_at}`
  if `opts[:flatten_at]` is neither `nil` nor a `Time`,
  `{:error, :invalid_sizing_vol}` for an unknown `opts[:sizing_vol]`, or a required
  `position_sizing` context value is missing for every symbol (nothing
  to backtest).
  """
  @spec run(map(), %{String.t() => [bar()]}, keyword()) ::
          {:ok, [run_result()]} | {:error, term()}
  def run(strategy, bars_by_symbol, opts \\ []) do
    signal_specs = Keyword.get(opts, :signal_specs, %{})
    literal_series = Keyword.get(opts, :literal_series, %{})

    entry_rule = get_in(strategy, ["rules", "entry"])
    exit_rule = get_in(strategy, ["rules", "exit"])

    needed_names =
      (RuleEngine.signal_names(entry_rule) ++ RuleEngine.signal_names(exit_rule))
      |> Enum.uniq()
      |> Enum.reject(&run_local?/1)

    with :ok <- validate_specs(needed_names, signal_specs),
         :ok <- validate_flatten_at(Keyword.get(opts, :flatten_at)),
         :ok <- validate_sizing_vol(Keyword.get(opts, :sizing_vol, :stdev)) do
      global_series = compute_global_series(signal_specs, bars_by_symbol, literal_series)

      runs =
        bars_by_symbol
        |> Enum.flat_map(fn {symbol, bars} ->
          walk_symbol(symbol, bars, strategy, signal_specs, global_series, opts)
        end)

      {:ok, runs}
    end
  end

  defp validate_flatten_at(nil), do: :ok
  defp validate_flatten_at(%Time{}), do: :ok
  defp validate_flatten_at(_other), do: {:error, :invalid_flatten_at}

  defp validate_sizing_vol(mode) when mode in [:stdev, :ewma], do: :ok
  defp validate_sizing_vol(_other), do: {:error, :invalid_sizing_vol}

  defp run_local?("run_" <> _), do: true
  defp run_local?(_), do: false

  defp validate_specs(needed_names, signal_specs) do
    missing = Enum.reject(needed_names, &Map.has_key?(signal_specs, &1))

    if missing == [] do
      :ok
    else
      {:error, {:missing_signal_specs, missing}}
    end
  end

  ## -----------------------------------------------------------------------
  ## Global (pool-independent) signal series
  ## -----------------------------------------------------------------------

  # Computes every :global-scoped spec's full {ts, value} series once,
  # independent of any symbol's own walk. Returns %{name => [{ts, value}, ...]}
  # in chronological order, ready for last-observation-carried-forward
  # lookup during each symbol's own walk.
  defp compute_global_series(signal_specs, bars_by_symbol, literal_series) do
    global_names =
      signal_specs
      |> Enum.filter(fn {_name, spec} -> global_spec?(spec, signal_specs) end)
      |> Enum.map(&elem(&1, 0))

    Enum.reduce(global_names, %{}, fn name, acc ->
      spec = Map.fetch!(signal_specs, name)
      series = compute_global_one(name, spec, signal_specs, bars_by_symbol, literal_series, acc)
      Map.put(acc, name, series)
    end)
  end

  defp global_spec?(%{kind: :series}, _specs), do: true
  defp global_spec?(%{kind: :price, symbol: _explicit}, _specs), do: true
  defp global_spec?(%{kind: :price}, _specs), do: false
  defp global_spec?(%{kind: :volume, symbol: _explicit}, _specs), do: true
  defp global_spec?(%{kind: :volume}, _specs), do: false
  defp global_spec?(%{kind: :vwap, symbol: _explicit}, _specs), do: true
  defp global_spec?(%{kind: :vwap}, _specs), do: false

  defp global_spec?(%{parent: parent}, specs),
    do: global_spec?(Map.fetch!(specs, parent), specs)

  defp global_spec?(%{value: value, reference: reference}, specs),
    do:
      global_spec?(Map.fetch!(specs, value), specs) and
        global_spec?(Map.fetch!(specs, reference), specs)

  defp global_spec?(%{direction: direction, gate: gate}, specs),
    do:
      global_spec?(Map.fetch!(specs, direction), specs) and
        global_spec?(Map.fetch!(specs, gate), specs)

  defp compute_global_one(name, %{kind: :series}, _specs, _bars_by_symbol, literal_series, _acc) do
    Map.get(literal_series, name, [])
  end

  defp compute_global_one(
         _name,
         %{kind: :price, symbol: symbol},
         _specs,
         bars_by_symbol,
         _literal,
         _acc
       ) do
    bars_by_symbol
    |> Map.get(symbol, [])
    |> Enum.map(&{&1.ts, &1.close})
  end

  defp compute_global_one(
         _name,
         %{kind: :volume, symbol: symbol},
         _specs,
         bars_by_symbol,
         _literal,
         _acc
       ) do
    bars_by_symbol
    |> Map.get(symbol, [])
    |> Enum.map(&{&1.ts, &1.volume})
  end

  defp compute_global_one(
         _name,
         %{kind: :vwap, symbol: symbol},
         _specs,
         bars_by_symbol,
         _literal,
         _acc
       ) do
    bars_by_symbol
    |> Map.get(symbol, [])
    |> Enum.map(&{&1.ts, Map.get(&1, :vwap)})
    |> drop_nil_values()
  end

  defp compute_global_one(name, spec, specs, bars_by_symbol, literal_series, acc) do
    parent_series =
      spec
      |> resolve_input_series(specs, bars_by_symbol, literal_series, acc)
      |> without_nil_inputs()

    replay_wrapping_signal(name, spec, parent_series)
  end

  # A nil entry in an input series (a literal_series gap, a bar without
  # :vwap) is "no value", not a number: strip it before replay, the same
  # way the per-symbol path skips a nil input. Two-input kinds still see
  # nil on one side before that side's first value (merge_series/2) and
  # handle it themselves.
  defp without_nil_inputs({series_a, series_b}),
    do: {drop_nil_values(series_a), drop_nil_values(series_b)}

  defp without_nil_inputs(series), do: drop_nil_values(series)

  # For a wrapping global spec, gathers the {ts, value} series (or pair of
  # series, for value/reference or direction/gate kinds) it needs — either
  # from `acc` (an already-computed global signal, per declaration-order
  # evaluation) or freshly for a base kind.
  defp resolve_input_series(%{parent: parent}, specs, bars_by_symbol, literal_series, acc) do
    fetch_series(parent, specs, bars_by_symbol, literal_series, acc)
  end

  defp resolve_input_series(
         %{value: value, reference: reference},
         specs,
         bars_by_symbol,
         literal_series,
         acc
       ) do
    {fetch_series(value, specs, bars_by_symbol, literal_series, acc),
     fetch_series(reference, specs, bars_by_symbol, literal_series, acc)}
  end

  defp resolve_input_series(
         %{direction: direction, gate: gate},
         specs,
         bars_by_symbol,
         literal_series,
         acc
       ) do
    {fetch_series(direction, specs, bars_by_symbol, literal_series, acc),
     fetch_series(gate, specs, bars_by_symbol, literal_series, acc)}
  end

  defp fetch_series(name, specs, bars_by_symbol, literal_series, acc) do
    case Map.fetch(acc, name) do
      {:ok, series} ->
        series

      :error ->
        spec = Map.fetch!(specs, name)
        compute_global_one(name, spec, specs, bars_by_symbol, literal_series, acc)
    end
  end

  # Walks a single {ts, value} parent series (derivative/momentum/wavelet/
  # self_zscore/donchian) or a merged pair of series (percent_deviation/
  # ratio/spread_zscore's value+reference, regime's direction+gate),
  # folding each new sample through the matching TradingCore.Signals
  # function to build the wrapping signal's own full {ts, value} series.
  # This mirrors compute_symbol_signal/5's per-bar dispatch but walks a
  # signal's own input series directly rather than a shared bar timeline,
  # since a :global signal's parent series may come from a different
  # symbol's bars (or a literal series) than whatever's being walked when
  # this global series is later sampled from.
  defp replay_wrapping_signal(_name, %{kind: :derivative} = spec, parent_series) do
    opts = signal_opts(spec)

    {series, _final_state} =
      Enum.map_reduce(parent_series, [], fn {ts, value}, history ->
        {new_history, result} = Signals.derivative(history, value, ts, opts)
        {{ts, result}, new_history}
      end)

    drop_nil_values(series)
  end

  defp replay_wrapping_signal(_name, %{kind: :momentum} = spec, parent_series) do
    opts = signal_opts(spec)

    {series, _final_state} =
      Enum.map_reduce(parent_series, [], fn {ts, value}, history ->
        {new_history, result} = Signals.momentum(history, value, ts, opts)
        {{ts, result}, new_history}
      end)

    drop_nil_values(series)
  end

  defp replay_wrapping_signal(_name, %{kind: :wavelet}, parent_series) do
    {series, _final_state} =
      Enum.map_reduce(parent_series, [], fn {ts, value}, window ->
        {new_window, result} = Signals.wavelet(window, value)
        {{ts, result}, new_window}
      end)

    drop_nil_values(series)
  end

  defp replay_wrapping_signal(_name, %{kind: :self_zscore} = spec, parent_series) do
    opts = signal_opts(spec)

    {series, _final_state} =
      Enum.map_reduce(parent_series, {[], TradingCore.WelfordAcc.new()}, fn {ts, value},
                                                                            {history, welford} ->
        {new_history, new_welford, result} =
          Signals.self_zscore(history, welford, value, ts, opts)

        {{ts, result}, {new_history, new_welford}}
      end)

    drop_nil_values(series)
  end

  defp replay_wrapping_signal(_name, %{kind: :donchian} = spec, parent_series) do
    opts = signal_opts(spec)

    {series, _final_state} =
      Enum.map_reduce(parent_series, [], fn {ts, value}, prices ->
        {new_prices, result} = Signals.donchian(prices, value, ts, opts)
        {{ts, result}, new_prices}
      end)

    drop_nil_values(series)
  end

  defp replay_wrapping_signal(
         _name,
         %{kind: :percent_deviation},
         {value_series, reference_series}
       ) do
    value_series
    |> merge_series(reference_series)
    |> Enum.map(fn {ts, value, reference} ->
      {ts, both_present(value, reference, &Signals.percent_deviation/2)}
    end)
    |> drop_nil_values()
  end

  defp replay_wrapping_signal(_name, %{kind: :ratio} = spec, {value_series, reference_series}) do
    opts = signal_opts(spec)

    value_series
    |> merge_series(reference_series)
    |> Enum.map(fn {ts, value, reference} ->
      {ts, both_present(value, reference, &Signals.ratio(&1, &2, opts))}
    end)
    |> drop_nil_values()
  end

  defp replay_wrapping_signal(
         _name,
         %{kind: :spread_zscore} = spec,
         {value_series, reference_series}
       ) do
    opts = signal_opts(spec)

    {series, _final_state} =
      value_series
      |> merge_series(reference_series)
      |> Enum.map_reduce({[], TradingCore.WelfordAcc.new()}, fn
        {ts, value, reference}, state when is_nil(value) or is_nil(reference) ->
          {{ts, nil}, state}

        {ts, value, reference}, {history, welford} ->
          {new_history, new_welford, result} =
            Signals.spread_zscore(history, welford, value, reference, ts, opts)

          {{ts, result}, {new_history, new_welford}}
      end)

    drop_nil_values(series)
  end

  defp replay_wrapping_signal(_name, %{kind: :regime} = spec, {direction_series, gate_series}) do
    tick_deadband = to_decimal(Map.fetch!(spec, :tick_deadband))
    vix_gate_zscore = to_decimal(Map.fetch!(spec, :vix_gate_zscore))

    direction_series
    |> merge_series(gate_series)
    |> Enum.map(fn {ts, direction, gate} ->
      {ts, both_present(direction, gate, &Signals.regime(&1, &2, tick_deadband, vix_gate_zscore))}
    end)
  end

  # Merges two chronological {ts, value} series into a single {ts, a, b}
  # series, sampling each side last-observation-carried-forward at every
  # timestamp present in either series — the same LOCF discipline
  # advance_cursors/2 uses for looking up a :global series against a symbol's
  # own bar timeline, applied here so a wrapping :global signal (e.g.
  # regime, built from two other :global series that may not share a
  # timestamp cadence) sees a coherent pair at every point.
  defp merge_series(series_a, series_b) do
    all_ts =
      (Enum.map(series_a, &elem(&1, 0)) ++ Enum.map(series_b, &elem(&1, 0)))
      |> Enum.uniq()
      |> Enum.sort({:asc, DateTime})

    {merged, _cursors} =
      Enum.map_reduce(all_ts, {series_a, nil, series_b, nil}, fn ts, {rest_a, a, rest_b, b} ->
        {rest_a, a} = advance(rest_a, a, ts)
        {rest_b, b} = advance(rest_b, b, ts)
        {{ts, a, b}, {rest_a, a, rest_b, b}}
      end)

    merged
  end

  defp drop_nil_values(series), do: Enum.reject(series, fn {_ts, value} -> is_nil(value) end)

  # A two-input signal has no value until both inputs do (one series can
  # start later than the other).
  defp both_present(a, b, _fun) when is_nil(a) or is_nil(b), do: nil
  defp both_present(a, b, fun), do: fun.(a, b)

  ## -----------------------------------------------------------------------
  ## Per-symbol walk
  ## -----------------------------------------------------------------------

  defp walk_symbol(symbol, bars, strategy, signal_specs, global_series, opts) do
    direction = Map.get(strategy, "direction", "long")
    entry_rule = get_in(strategy, ["rules", "entry"])
    exit_rule = get_in(strategy, ["rules", "exit"])
    risk_controls_config = get_in(strategy, ["params", "risk_controls"])
    exit_strategy_config = get_in(strategy, ["params", "exit_strategy"])

    position_sizing_config =
      Map.get(strategy, "position_sizing", %{"method" => "fixed_qty", "qty" => 1})

    symbol_names =
      signal_specs
      |> Enum.reject(fn {_name, spec} -> global_spec?(spec, signal_specs) end)
      |> Enum.map(&elem(&1, 0))
      |> topo_sort(signal_specs)

    initial_signal_state =
      Map.new(symbol_names, fn name -> {name, fresh_state(Map.fetch!(signal_specs, name))} end)

    # Pair each bar with its successor up front: Enum.at/2 inside the
    # loop made the walk quadratic, which minute bars can't afford.
    indexed_pairs = bars |> Enum.zip(Enum.drop(bars, 1) ++ [nil]) |> Enum.with_index()
    flatten_at = Keyword.get(opts, :flatten_at)
    intrabar? = Keyword.get(opts, :intrabar, false)

    # Built once per symbol; only volatility_target sizing reads it.
    opts =
      if match?(%{"method" => "volatility_target"}, position_sizing_config),
        do: Keyword.put(opts, :__day_index__, day_index(bars)),
        else: opts

    acc = %{
      signal_state: initial_signal_state,
      position: nil,
      runs: [],
      sessions: %{},
      # name => {series entries not yet reached, latest value reached}
      global_cursors: Map.new(global_series, fn {name, series} -> {name, {series, nil}} end)
    }

    final =
      Enum.reduce(indexed_pairs, acc, fn {{bar, next_bar}, index}, acc ->
        {global_values, global_cursors} = advance_cursors(acc.global_cursors, bar.ts)

        {snapshot, new_signal_state} =
          build_snapshot(bar, symbol_names, signal_specs, acc.signal_state, global_values)

        acc = %{acc | global_cursors: global_cursors}

        {session, next_session, sessions} =
          bar_sessions(bar, next_bar, flatten_at, acc.sessions)

        acc = %{acc | signal_state: new_signal_state, sessions: sessions}

        case acc.position do
          nil ->
            if entry_allowed?(bar, next_bar, session, next_session) do
              maybe_enter(
                acc,
                symbol,
                bar,
                next_bar,
                snapshot,
                entry_rule,
                direction,
                risk_controls_config,
                position_sizing_config,
                bars,
                index,
                opts
              )
            else
              acc
            end

          position ->
            maybe_exit(
              acc,
              symbol,
              bar,
              next_bar,
              snapshot,
              position,
              exit_rule,
              exit_strategy_config,
              direction,
              intrabar?,
              flatten_now?(bar, next_bar, session, next_session)
            )
        end
      end)

    runs = force_close_open_position(final, symbol, List.last(bars))

    Enum.reverse(runs)
  end

  ## -----------------------------------------------------------------------
  ## End-of-session flatten (opts[:flatten_at])
  ## -----------------------------------------------------------------------

  # Without :flatten_at nothing is session-aware: every bar may enter and
  # nothing is flattened, exactly as before the option existed.
  defp bar_sessions(_bar, _next_bar, nil, sessions), do: {nil, nil, sessions}

  defp bar_sessions(bar, next_bar, flatten_at, sessions) do
    {session, sessions} = session_for(bar, flatten_at, sessions)
    {next_session, sessions} = session_for(next_bar, flatten_at, sessions)
    {session, next_session, sessions}
  end

  defp session_for(nil, _flatten_at, sessions), do: {nil, sessions}

  # Session facts for the US/Eastern date a bar falls on, cached per date.
  # `cutoff` is flatten_at on that date, kept the same distance before an
  # early close (15:55 -> 12:55 on a 13:00 half day). A date with no
  # session (weekend, holiday) has `open`/`cutoff` nil.
  defp session_for(%{ts: ts}, flatten_at, sessions) do
    date = ts |> DateTime.shift_zone!(@eastern) |> DateTime.to_date()

    case Map.fetch(sessions, date) do
      {:ok, session} ->
        {session, sessions}

      :error ->
        session =
          case RegularSession.bounds(date) do
            {:ok, open, close} ->
              before_close = max(Time.diff(@regular_close, flatten_at), 0)
              %{date: date, open: open, cutoff: DateTime.add(close, -before_close, :second)}

            :error ->
              %{date: date, open: nil, cutoff: nil}
          end

        {session, Map.put(sessions, date, session)}
    end
  end

  # An entry fills at next_bar's open, so it is allowed only when both the
  # signal bar and the fill bar are inside the same session, at or after
  # its open and before its cutoff: nothing fills into the flatten window,
  # overnight, or pre-market.
  defp entry_allowed?(_bar, _next_bar, nil, _next_session), do: true
  defp entry_allowed?(_bar, nil, _session, _next_session), do: true

  defp entry_allowed?(bar, next_bar, session, next_session) do
    session.open != nil and next_session.date == session.date and
      in_window?(bar.ts, session) and in_window?(next_bar.ts, session)
  end

  defp in_window?(ts, %{open: open, cutoff: cutoff}) do
    DateTime.compare(ts, open) != :lt and DateTime.compare(ts, cutoff) == :lt
  end

  # Flatten on this bar when it is at/after the session's cutoff, outside
  # any session, or the last bar of its session (a data gap must not let a
  # position ride overnight). When the data ends, the final bar flattens
  # only if its minute reaches the cutoff (data ending on the session's
  # last minute bar); data that stops mid-session stays end_of_data.
  defp flatten_now?(_bar, _next_bar, nil, _next_session), do: false

  defp flatten_now?(bar, next_bar, session, next_session) do
    session.cutoff == nil or DateTime.compare(bar.ts, session.cutoff) != :lt or
      DateTime.compare(bar.ts, session.open) == :lt or
      (next_bar != nil and next_session.date != session.date) or
      (next_bar == nil and DateTime.diff(session.cutoff, bar.ts) <= 60)
  end

  defp fresh_state(%{kind: :self_zscore}), do: {[], TradingCore.WelfordAcc.new()}
  defp fresh_state(%{kind: :spread_zscore}), do: {[], TradingCore.WelfordAcc.new()}
  defp fresh_state(%{kind: :wavelet}), do: []
  defp fresh_state(_other), do: []

  # `signal_specs` is a plain map -- Elixir gives no ordering guarantee
  # over its keys, so a wrapping signal's `parent`/`value`/`reference`
  # dependency cannot rely on "declared earlier" meaning "computed
  # earlier" the way this module's moduledoc describes for :global specs
  # (where evaluation order is enforced by fetch_series/5's
  # compute-on-demand memoization instead). For the per-bar :symbol-scoped
  # walk, a plain reduce needs its evaluation order fixed up front instead
  # — this is a straightforward dependency-ordering (topological) sort: a
  # signal name gets placed only once every name it depends on (via
  # `parent`, or `value`+`reference`, or `direction`+`gate` -- only among
  # `names`, since a :global dependency is resolved separately, via
  # `global_series`, and never appears in `names` here) already has a
  # place. `names` themselves are deduplicated but otherwise order isn't
  # assumed meaningful going in.
  defp topo_sort(names, signal_specs) do
    name_set = MapSet.new(names)

    {ordered, _visited} =
      Enum.reduce(names, {[], MapSet.new()}, fn name, {ordered, visited} ->
        visit(name, signal_specs, name_set, ordered, visited)
      end)

    Enum.reverse(ordered)
  end

  defp visit(name, specs, name_set, ordered, visited) do
    if MapSet.member?(visited, name) do
      {ordered, visited}
    else
      visited = MapSet.put(visited, name)

      deps =
        spec_dependencies(Map.fetch!(specs, name)) |> Enum.filter(&MapSet.member?(name_set, &1))

      {ordered, visited} =
        Enum.reduce(deps, {ordered, visited}, fn dep, {ordered, visited} ->
          visit(dep, specs, name_set, ordered, visited)
        end)

      {[name | ordered], visited}
    end
  end

  defp spec_dependencies(%{parent: parent}), do: [parent]
  defp spec_dependencies(%{value: value, reference: reference}), do: [value, reference]
  defp spec_dependencies(%{direction: direction, gate: gate}), do: [direction, gate]
  defp spec_dependencies(_base_spec), do: []

  ## -----------------------------------------------------------------------
  ## Snapshot construction (per bar)
  ## -----------------------------------------------------------------------

  defp build_snapshot(bar, symbol_names, signal_specs, signal_state, global_values) do
    {values, new_state} =
      Enum.reduce(symbol_names, {%{}, signal_state}, fn name, {values, state} ->
        spec = Map.fetch!(signal_specs, name)
        {value, new_state_for_name} = compute_symbol_signal(name, spec, bar, values, state)
        {Map.put(values, name, value), Map.put(state, name, new_state_for_name)}
      end)

    snapshot =
      values
      |> Map.merge(global_values)
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    {snapshot, new_state}
  end

  # Each global series is sampled as of each bar: the value of its latest
  # entry at or before `ts` (nil before its first entry). Bars and series
  # are both chronological, so a cursor that only moves forward gives the
  # same answer as searching from the start, in linear time overall.
  defp advance_cursors(cursors, ts) do
    Enum.reduce(cursors, {%{}, cursors}, fn {name, {rest, current}}, {values, cursors} ->
      {rest, current} = advance(rest, current, ts)
      {Map.put(values, name, current), Map.put(cursors, name, {rest, current})}
    end)
  end

  defp advance([{entry_ts, value} | rest] = series, current, ts) do
    if DateTime.compare(entry_ts, ts) != :gt,
      do: advance(rest, value, ts),
      else: {series, current}
  end

  defp advance([], current, _ts), do: {[], current}

  defp compute_symbol_signal(name, %{kind: :price}, bar, _values, state) do
    {bar.close, Map.fetch!(state, name)}
  end

  defp compute_symbol_signal(name, %{kind: :volume}, bar, _values, state) do
    {bar.volume, Map.fetch!(state, name)}
  end

  defp compute_symbol_signal(name, %{kind: :vwap}, bar, _values, state) do
    {Map.get(bar, :vwap), Map.fetch!(state, name)}
  end

  defp compute_symbol_signal(name, %{kind: :derivative} = spec, bar, values, state) do
    history = Map.fetch!(state, name)
    parent_value = parent_value_for(spec, bar, values)
    opts = signal_opts(spec)

    case parent_value do
      nil ->
        {nil, history}

      parent_value ->
        {new_history, value} = Signals.derivative(history, parent_value, bar.ts, opts)
        {value, new_history}
    end
  end

  defp compute_symbol_signal(name, %{kind: :momentum} = spec, bar, values, state) do
    history = Map.fetch!(state, name)
    parent_value = parent_value_for(spec, bar, values)
    opts = signal_opts(spec)

    case parent_value do
      nil ->
        {nil, history}

      parent_value ->
        {new_history, value} = Signals.momentum(history, parent_value, bar.ts, opts)
        {value, new_history}
    end
  end

  defp compute_symbol_signal(name, %{kind: :wavelet} = spec, bar, values, state) do
    window = Map.fetch!(state, name)
    parent_value = parent_value_for(spec, bar, values)

    case parent_value do
      nil ->
        {nil, window}

      parent_value ->
        {new_window, value} = Signals.wavelet(window, parent_value)
        {value, new_window}
    end
  end

  defp compute_symbol_signal(name, %{kind: :self_zscore} = spec, bar, values, state) do
    {history, welford} = Map.fetch!(state, name)
    parent_value = parent_value_for(spec, bar, values)
    opts = signal_opts(spec)

    case parent_value do
      nil ->
        {nil, {history, welford}}

      parent_value ->
        {new_history, new_welford, value} =
          Signals.self_zscore(history, welford, parent_value, bar.ts, opts)

        {value, {new_history, new_welford}}
    end
  end

  defp compute_symbol_signal(name, %{kind: :spread_zscore} = spec, bar, values, state) do
    {history, welford} = Map.fetch!(state, name)
    {value_v, reference_v} = value_reference_for(spec, bar, values)
    opts = signal_opts(spec)

    if is_nil(value_v) or is_nil(reference_v) do
      {nil, {history, welford}}
    else
      {new_history, new_welford, value} =
        Signals.spread_zscore(history, welford, value_v, reference_v, bar.ts, opts)

      {value, {new_history, new_welford}}
    end
  end

  defp compute_symbol_signal(_name, %{kind: :percent_deviation} = spec, bar, values, _state) do
    history = []
    {value_v, reference_v} = value_reference_for(spec, bar, values)

    result =
      if is_nil(value_v) or is_nil(reference_v),
        do: nil,
        else: Signals.percent_deviation(value_v, reference_v)

    {result, history}
  end

  defp compute_symbol_signal(_name, %{kind: :ratio} = spec, bar, values, _state) do
    history = []
    {value_v, reference_v} = value_reference_for(spec, bar, values)
    opts = signal_opts(spec)

    result =
      if is_nil(value_v) or is_nil(reference_v),
        do: nil,
        else: Signals.ratio(value_v, reference_v, opts)

    {result, history}
  end

  defp compute_symbol_signal(name, %{kind: :donchian} = spec, bar, values, state) do
    prices = Map.fetch!(state, name)
    parent_value = parent_value_for(spec, bar, values)
    opts = signal_opts(spec)

    case parent_value do
      nil ->
        {nil, prices}

      parent_value ->
        {new_prices, value} = Signals.donchian(prices, parent_value, bar.ts, opts)
        {value, new_prices}
    end
  end

  defp compute_symbol_signal(_name, %{kind: :regime} = spec, bar, values, _state) do
    {direction_v, gate_v} = direction_gate_for(spec, bar, values)
    tick_deadband = Map.fetch!(spec, :tick_deadband)
    vix_gate_zscore = Map.fetch!(spec, :vix_gate_zscore)

    result =
      if is_nil(direction_v) or is_nil(gate_v),
        do: nil,
        else:
          Signals.regime(
            direction_v,
            gate_v,
            to_decimal(tick_deadband),
            to_decimal(vix_gate_zscore)
          )

    {result, []}
  end

  defp parent_value_for(%{parent: parent}, _bar, values), do: Map.get(values, parent)

  defp value_reference_for(%{value: value_name, reference: reference_name}, _bar, values) do
    {Map.get(values, value_name), Map.get(values, reference_name)}
  end

  defp direction_gate_for(%{direction: direction_name, gate: gate_name}, _bar, values) do
    {Map.get(values, direction_name), Map.get(values, gate_name)}
  end

  defp signal_opts(spec) do
    spec
    |> Map.take([
      :window_ms,
      :precision,
      :max_history_samples,
      :sample_interval_ms,
      :on_cap_bound,
      :min_span_ms
    ])
    |> Enum.into([])
  end

  ## -----------------------------------------------------------------------
  ## Entry
  ## -----------------------------------------------------------------------

  defp maybe_enter(
         acc,
         _symbol,
         _bar,
         next_bar,
         snapshot,
         entry_rule,
         direction,
         risk_controls_config,
         position_sizing_config,
         bars,
         index,
         opts
       ) do
    if next_bar != nil and RuleEngine.evaluate(entry_rule, snapshot) do
      entry_price = next_bar.open
      entry_at = next_bar.ts

      entry_vol = entry_daily_vol(risk_controls_config, bars, index, opts)

      levels =
        RiskControls.resolve_levels(
          entry_price,
          risk_controls_config,
          direction,
          if(entry_vol, do: [daily_vol: entry_vol], else: [])
        )

      {stop_loss_price, take_profit_price} =
        round_number_levels(levels, entry_price, direction, entry_vol, opts)

      sizing_context =
        build_sizing_context(position_sizing_config, entry_price, bars, index, opts)

      case PositionSizing.calculate_qty(position_sizing_config, sizing_context) do
        {:ok, qty} ->
          position = %{
            entry_at: entry_at,
            entry_price: entry_price,
            direction: direction,
            stop_loss_price: stop_loss_price,
            take_profit_price: take_profit_price,
            # As set at entry; the ratchet later moves stop_loss_price and
            # may clear take_profit_price.
            entry_stop_loss_price: stop_loss_price,
            entry_take_profit_price: take_profit_price,
            stop_method: levels.method,
            stop_daily_vol: levels.daily_vol,
            qty: qty,
            state: %{}
          }

          %{acc | position: position}

        {:error, _reason} ->
          # Can't size this entry (e.g. volatility_target with too few
          # trailing bars to estimate daily_vol yet) — skip this signal,
          # stay flat, try again on a later bar.
          acc
      end
    else
      acc
    end
  end

  # The daily vol a live entry would be handed: the hub's EWMA
  # (Volatility.ewma_daily_vol/2) over bars up to and including the signal
  # bar — what was known when the entry fired. Needed by a
  # "volatility_multiple" stop and by the round-number buffer; nil when
  # neither is in use or there is too little history (RiskControls then
  # falls back to percent_of_entry and the run records that).
  defp entry_daily_vol(risk_controls_config, bars, index, opts) do
    needed? =
      match?(%{"method" => "volatility_multiple"}, risk_controls_config) or
        Keyword.get(opts, :round_numbers) != nil

    if needed? do
      known = Enum.take(bars, index + 1)

      as_of =
        known
        |> List.last()
        |> Map.fetch!(:ts)
        |> DateTime.shift_zone!("Etc/UTC")
        |> DateTime.to_date()

      vol_opts = [
        as_of: as_of,
        lookback_days: Keyword.get(opts, :stop_vol_lookback_days, 14),
        lambda: Keyword.get(opts, :stop_vol_lambda, 0.94)
      ]

      case Volatility.ewma_daily_vol(known, vol_opts) do
        {:ok, daily_vol} -> daily_vol
        :insufficient_data -> nil
      end
    end
  end

  # opts[:round_numbers] (a keyword list of RoundNumbers.adjust/4 options)
  # moves both levels off the crowded side of round numbers; absent, the
  # levels pass through untouched.
  defp round_number_levels(levels, entry_price, direction, daily_vol, opts) do
    case Keyword.get(opts, :round_numbers) do
      nil ->
        {levels.stop_loss, levels.take_profit}

      rn_opts ->
        rn_opts =
          Keyword.merge([daily_vol: daily_vol, price: entry_price, entry: entry_price], rn_opts)

        {RoundNumbers.adjust(levels.stop_loss, :stop_loss, direction, rn_opts),
         RoundNumbers.adjust(levels.take_profit, :take_profit, direction, rn_opts)}
    end
  end

  defp build_sizing_context(%{"method" => "volatility_target"}, entry_price, bars, index, opts) do
    window = Keyword.get(opts, :volatility_window, @default_volatility_window)
    target_dollar_volatility = Keyword.fetch!(opts, :target_dollar_volatility)

    day_index = Keyword.get_lazy(opts, :__day_index__, fn -> day_index(bars) end)

    estimate =
      case Keyword.get(opts, :sizing_vol, :stdev) do
        :ewma ->
          ewma_daily_vol_at(day_index, index, opts)

        :stdev ->
          daily_vol_at(day_index, index, window)
      end

    case estimate do
      {:ok, daily_vol} ->
        %{
          daily_vol: daily_vol,
          price: entry_price,
          target_dollar_volatility: target_dollar_volatility,
          # A backtest never submits a real broker order — nothing here
          # is subject to IBKR's live-order fractional-share restriction
          # (see PositionSizing's own moduledoc, "Fractional shares"), so
          # this always uses the exact theoretical quantity rather than
          # rounding, for the most accurate simulated P&L.
          fractional_shares_enabled: true
        }

      :insufficient_data ->
        %{}
    end
  end

  defp build_sizing_context(_config, _entry_price, _bars, _index, _opts), do: %{}

  @doc """
  Estimates a `daily_vol` figure (fractional stdev of close-to-close
  **daily** returns, e.g. `0.02` for 2%) as of the bar at `index`, from
  the last `window` daily closes up to and including that bar — the
  backtest stand-in for the live `daily_vol` RPC `"volatility_target"`
  sizing needs (see `TradingCore.PositionSizing.calculate_qty/2`).

  Bars are first collapsed to **one close per US/Eastern trading day**:
  the close of that day's last regular-session bar (09:30 ET to the
  close), so pre- and post-market bars never stand in for the close, or
  the day's last bar when it has no regular-session bar at all (daily
  bars, whose timestamps sit outside the session). The bar at `index`
  supplies the current day's close so far. For daily bars this is the
  same as using the trailing `window` bars directly; for intraday bars
  it is what makes the figure a *daily* volatility. (Before 2026-10-03
  intraday bars were used one-per-"day", so minute bars produced roughly
  a 20-minute volatility and sized positions about √390 ≈ 20× too large.)

  Returns `{:ok, daily_vol}`, or `:insufficient_data` when fewer than 2
  daily closes (hence fewer than 1 return) are available yet — same "not
  enough history" gap a freshly-started live volatility service would
  also have, just resolved differently (a backtest can't fall back to
  "wait for more ticks," it just can't size this particular entry).

  This is a simple realized-volatility estimate, not a reconstruction of
  whatever `trading_hub`'s own volatility RPC actually computes — see this
  module's moduledoc, "`\"volatility_target\"` sizing's `daily_vol` is
  estimated, not fetched," for why the two are not guaranteed to agree
  even given identical price history.
  """
  @spec estimate_daily_vol([bar()], non_neg_integer(), pos_integer()) ::
          {:ok, Decimal.t()} | :insufficient_data
  def estimate_daily_vol(bars, index, window) do
    bars |> Enum.take(index + 1) |> day_index() |> daily_vol_at(index, window)
  end

  # Per-bar facts for daily-close lookups, built in one pass: each bar's
  # US/Eastern date, whether it is inside that date's regular session,
  # its close, and every date's ordered index of bars.
  defp day_index(bars) do
    {rows, _cache} =
      Enum.map_reduce(bars, %{}, fn bar, cache ->
        date = bar.ts |> DateTime.shift_zone!(@eastern) |> DateTime.to_date()

        {bounds, cache} =
          case Map.fetch(cache, date) do
            {:ok, bounds} -> {bounds, cache}
            :error -> RegularSession.bounds(date) |> then(&{&1, Map.put(cache, date, &1)})
          end

        regular? =
          match?({:ok, _, _}, bounds) and
            DateTime.compare(bar.ts, elem(bounds, 1)) != :lt and
            DateTime.compare(bar.ts, elem(bounds, 2)) == :lt

        {{date, regular?, bar.close}, cache}
      end)

    rows = List.to_tuple(rows)

    # date => {last regular-session index | nil, last index}, plus the
    # dates in order.
    {last_by_date, dates} =
      rows
      |> Tuple.to_list()
      |> Enum.with_index()
      |> Enum.reduce({%{}, []}, fn {{date, regular?, _close}, i}, {acc, dates} ->
        dates = if Map.has_key?(acc, date), do: dates, else: [date | dates]

        acc =
          Map.update(acc, date, {if(regular?, do: i), i}, fn {last_regular, _last} ->
            {if(regular?, do: i, else: last_regular), i}
          end)

        {acc, dates}
      end)

    %{rows: rows, last_by_date: last_by_date, dates: Enum.reverse(dates)}
  end

  defp daily_vol_at(%{rows: rows}, index, _window) when index >= tuple_size(rows),
    do: :insufficient_data

  defp daily_vol_at(day_index, index, window) do
    trailing = day_index |> daily_closes_at(index, window) |> Enum.map(&elem(&1, 1))

    if length(trailing) < 2 do
      :insufficient_data
    else
      returns =
        trailing
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [prev, curr] -> Decimal.div(Decimal.sub(curr, prev), prev) end)

      {:ok, stdev(returns)}
    end
  end

  # The last `count` daily closes as of the bar at `index`, oldest first,
  # as {date, close}: prior days' closes, then today's close so far.
  defp daily_closes_at(%{rows: rows, last_by_date: last_by_date, dates: dates}, index, count) do
    {today, _regular?, _close} = elem(rows, index)

    prior =
      dates
      |> Enum.take_while(&(Date.compare(&1, today) == :lt))
      |> Enum.take(-(count - 1))
      |> Enum.map(fn date ->
        {last_regular, last} = Map.fetch!(last_by_date, date)
        {date, rows |> elem(last_regular || last) |> elem(2)}
      end)

    prior ++ [{today, today_close(rows, index, today)}]
  end

  # The hub's estimator (TradingCore.Volatility.ewma_daily_vol/2, which
  # matches trailing_ewma_vol_sync/4) over the same daily closes. Its
  # window is calendar days, so `lookback_days + 1` closes always cover it.
  defp ewma_daily_vol_at(%{rows: rows} = day_index, index, opts) when index < tuple_size(rows) do
    lookback_days = Keyword.get(opts, :sizing_vol_lookback_days, @hub_vol_lookback_days)
    {today, _regular?, _close} = elem(rows, index)

    day_index
    |> daily_closes_at(index, lookback_days + 1)
    |> Enum.map(fn {date, close} -> %{ts: date, close: close} end)
    |> Volatility.ewma_daily_vol(
      as_of: today,
      lookback_days: lookback_days,
      lambda: Keyword.get(opts, :sizing_vol_lambda, @hub_vol_lambda)
    )
  end

  defp ewma_daily_vol_at(_day_index, _index, _opts), do: :insufficient_data

  # Today's close so far: the latest regular-session bar at or before
  # `index` on `today`, else the bar at `index` itself.
  defp today_close(rows, index, today) do
    index
    |> Stream.iterate(&(&1 - 1))
    |> Stream.take_while(&(&1 >= 0 and elem(elem(rows, &1), 0) == today))
    |> Enum.find(index, &elem(elem(rows, &1), 1))
    |> then(&(rows |> elem(&1) |> elem(2)))
  end

  defp stdev(decimals) do
    n = length(decimals)
    mean = Enum.reduce(decimals, Decimal.new(0), &Decimal.add/2) |> Decimal.div(n)

    variance =
      decimals
      |> Enum.map(fn x -> x |> Decimal.sub(mean) |> Decimal.mult(Decimal.sub(x, mean)) end)
      |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
      |> Decimal.div(n)

    variance
    |> Decimal.to_float()
    |> :math.sqrt()
    |> Decimal.from_float()
  end

  ## -----------------------------------------------------------------------
  ## Exit
  ## -----------------------------------------------------------------------

  defp maybe_exit(
         acc,
         symbol,
         bar,
         next_bar,
         snapshot,
         position,
         exit_rule,
         exit_strategy_config,
         direction,
         intrabar?,
         flatten_now?
       ) do
    {intrabar_hit, position} =
      if intrabar?,
        do: intrabar_step(position, bar, direction, exit_strategy_config),
        else: {nil, position}

    case intrabar_hit do
      {reason, fill_price} ->
        run = close_run(symbol, position, position.direction, fill_price, bar.ts, reason)
        %{acc | position: nil, runs: [run | acc.runs]}

      # An intrabar stop/target on this bar happened before its close, so
      # it wins; otherwise the flatten fills at this bar's close.
      _ when flatten_now? ->
        run = close_run(symbol, position, position.direction, bar.close, bar.ts, "eod_flatten")
        %{acc | position: nil, runs: [run | acc.runs]}

      _ ->
        close_exit(
          acc,
          symbol,
          bar,
          next_bar,
          snapshot,
          position,
          exit_rule,
          exit_strategy_config,
          direction
        )
    end
  end

  defp close_exit(
         acc,
         symbol,
         bar,
         next_bar,
         snapshot,
         position,
         exit_rule,
         exit_strategy_config,
         direction
       ) do
    current_price = bar.close

    position = apply_ratchet(position, current_price, direction, exit_strategy_config)

    exit_snapshot =
      Map.merge(snapshot, %{
        "run_current_price" => current_price,
        "run_stop_loss_price" => position.stop_loss_price,
        "run_take_profit_price" => position.take_profit_price
      })

    reason = exit_reason(position, exit_snapshot, exit_rule, current_price, direction)

    cond do
      reason != nil and next_bar != nil ->
        run = close_run(symbol, position, position.direction, next_bar.open, next_bar.ts, reason)
        %{acc | position: nil, runs: [run | acc.runs]}

      true ->
        %{acc | position: position}
    end
  end

  defp apply_ratchet(position, _current_price, _direction, nil), do: position

  defp apply_ratchet(position, current_price, direction, exit_strategy_config) do
    case ExitStrategy.check(
           position.entry_price,
           current_price,
           direction,
           exit_strategy_config,
           position.state
         ) do
      {:ratchet, new_stop, state_updates} ->
        %{
          position
          | stop_loss_price: new_stop,
            take_profit_price: nil,
            state: Map.merge(position.state, state_updates)
        }

      {:trail, new_stop, state_updates} ->
        %{position | stop_loss_price: new_stop, state: Map.merge(position.state, state_updates)}

      :no_ratchet ->
        position
    end
  end

  # SL/TP first, unconditionally; the custom exit rule only when neither
  # was hit. See "Exits" in the moduledoc.
  defp exit_reason(position, exit_snapshot, exit_rule, current_price, direction) do
    cond do
      hit_stop_loss?(position, current_price, direction) -> "stopped_out"
      hit_take_profit?(position, current_price, direction) -> "target_hit"
      custom_rule?(exit_rule) and RuleEngine.evaluate(exit_rule, exit_snapshot) -> "rule_exit"
      true -> nil
    end
  end

  # An empty/missing exit rule means "no custom exit," not "exit now" —
  # RuleEngine.evaluate/2 would call it vacuously true.
  defp custom_rule?(exit_rule), do: is_map(exit_rule) and map_size(exit_rule) > 0

  # {reason, fill_price} if the bar's range reached a level, else nil. The
  # stop wins a bar that touched both (order inside the bar is unknown).
  # One bar with intrabar: true, in live's order (see "Exits" in the
  # moduledoc): the stop as of the bar's open against the adverse extreme;
  # then the exit strategy at the favourable extreme, which may ratchet
  # (clearing the take-profit) or trail; then the take-profit. Returns
  # {exit | nil, position}, the position carrying any moved levels.
  defp intrabar_step(position, bar, direction, exit_strategy_config) do
    {adverse, favourable} =
      if direction == "short", do: {bar.high, bar.low}, else: {bar.low, bar.high}

    if hit_stop_loss?(position, adverse, direction) do
      {{"stopped_out", gap_fill(position.stop_loss_price, bar.open, adverse_side(direction))},
       position}
    else
      case exit_strategy_check(position, favourable, direction, exit_strategy_config) do
        {:ratchet, _new_stop, _updates} ->
          if target_before_trigger?(position, favourable, direction, exit_strategy_config),
            do: {target_exit(position, bar, direction), position},
            else: {nil, apply_ratchet(position, favourable, direction, exit_strategy_config)}

        _trail_or_none ->
          if hit_take_profit?(position, favourable, direction),
            do: {target_exit(position, bar, direction), position},
            else: {nil, apply_ratchet(position, favourable, direction, exit_strategy_config)}
      end
    end
  end

  defp exit_strategy_check(position, price, direction, config),
    do: ExitStrategy.check(position.entry_price, price, direction, config, position.state)

  # The take-profit is reached before a ratchet trigger only when the
  # trigger lies beyond it: the ratchet would not yet fire at the
  # take-profit price itself.
  defp target_before_trigger?(%{take_profit_price: nil}, _favourable, _direction, _config),
    do: false

  defp target_before_trigger?(position, favourable, direction, config) do
    hit_take_profit?(position, favourable, direction) and
      exit_strategy_check(position, position.take_profit_price, direction, config) ==
        :no_ratchet
  end

  defp target_exit(position, bar, direction),
    do: {"target_hit", gap_fill(position.take_profit_price, bar.open, favourable_side(direction))}

  defp adverse_side("short"), do: :gt
  defp adverse_side(_long), do: :lt

  defp favourable_side("short"), do: :lt
  defp favourable_side(_long), do: :gt

  # Fill at `level`, unless the bar opened already beyond it in the
  # `beyond` direction — then at the open, the first price available.
  defp gap_fill(level, open, beyond) do
    if Decimal.compare(open, level) == beyond, do: open, else: level
  end

  defp hit_stop_loss?(position, current_price, direction),
    do: RiskControls.hit_stop_loss?(position.stop_loss_price, current_price, direction)

  defp hit_take_profit?(position, current_price, direction),
    do: RiskControls.hit_take_profit?(position.take_profit_price, current_price, direction)

  defp force_close_open_position(%{position: nil, runs: runs}, _symbol, _last_bar), do: runs

  defp force_close_open_position(%{position: position, runs: runs}, symbol, last_bar) do
    run =
      close_run(symbol, position, position.direction, last_bar.close, last_bar.ts, "end_of_data")

    [run | runs]
  end

  defp close_run(symbol, position, direction, exit_price, exit_at, exit_reason) do
    pnl =
      case direction do
        "short" -> Decimal.sub(position.entry_price, exit_price)
        _long -> Decimal.sub(exit_price, position.entry_price)
      end
      |> Decimal.mult(position.qty)

    %{
      symbol: symbol,
      direction: direction,
      entry_at: position.entry_at,
      entry_price: position.entry_price,
      exit_at: exit_at,
      exit_price: exit_price,
      exit_reason: exit_reason,
      stop_method: Map.get(position, :stop_method),
      stop_daily_vol: Map.get(position, :stop_daily_vol),
      entry_stop_loss_price: Map.get(position, :entry_stop_loss_price),
      entry_take_profit_price: Map.get(position, :entry_take_profit_price),
      qty: position.qty,
      pnl: pnl
    }
  end

  defp to_decimal(%Decimal{} = value), do: value
  defp to_decimal(value) when is_float(value), do: Decimal.from_float(value)
  defp to_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp to_decimal(value) when is_binary(value), do: Decimal.new(value)
end
