# Signals guide

Every signal kind `TradingCore.Signal.Compute` can compute, what it
measures, what it needs on the tick, and how to configure it.

22 kinds in three families. All are pure: `init/1` builds state, `step/2`
folds one tick, `replay/3` runs a whole series. No GenServer, no Ecto, no
wall clock — which is what makes a replay reproduce a live run exactly.

---

## How to use any kind

```elixir
alias TradingCore.Signal.{Compute, Spec}

spec = %Spec{
  kind: :book_imbalance,
  symbol: "SPY",
  window_ms: :timer.minutes(5),
  params: %{"precision" => 4}
}

{:ok, state} = Compute.init(spec)
{state, value} = Compute.step(spec, state, tick)
```

`value` is a `Decimal` (or float for `:two_scale_rv`), or the atom
**`:warming_up`** when the kind has not yet seen enough to emit. That is
never an error — it means "genuinely nothing to say yet", and live and
replay agree tick-for-tick on when it ends.

### The tick

```elixir
%{
  at: DateTime.t(),            # required
  value: price | nil,          # the primary input (a trade price for most kinds)
  reference: price | nil,      # second input: dual-parent kinds, :spread's X leg
  volume: size | nil,          # :volume, :vwap, :rolling_volume, :signed_volume, :kyle_lambda
  bid: price, ask: price,      # microstructure kinds
  bid_size: size, ask_size: size
}
```

A tick may carry **one side of the book only** — IBKR sends
`%{bid:, bid_size:}` then separately `%{ask:, ask_size:}`.
`merge_quote/3` holds the last known state of each side, so a kind always
sees a complete book. Polygon/Massive sends all four at once, making the
merge a no-op.

### Config that applies almost everywhere

| | where | meaning |
|---|---|---|
| `window_ms` | **`Spec` field, not `params`** | rolling window length |
| `params["precision"]` | params | decimal places on the emitted value |
| `params["max_history_samples"]` | params | hard cap on retained samples |

`window_ms` being a struct field is a common mistake — putting it in
`params` is silently ignored.

---

## Family 1: base kinds

Own their own `symbol`/`source` and read raw ticks. No parent.

### Price and trend

| kind | computes | needs | key params |
|---|---|---|---|
| `:plain` | the price itself, passed through | `value` | — |
| `:momentum` | change over the window | `value` | `window_ms` |
| `:donchian` | breakout vs. the window's high/low channel | `value` | `window_ms` |

### Volume

| kind | computes | needs | key params |
|---|---|---|---|
| `:volume` | cumulative session volume | `value` | `session_reset` |
| `:vwap` | volume-weighted average price | `value`, `volume` | `session_reset` |
| `:rolling_volume` | volume over a rolling window | `value` | `window_ms` |

`session_reset` is an injected 1-arity function
`DateTime.t() -> term()` (canonically
`TradingCore.Session.us_equities/1`). Without it a cumulative total grows
across days, which is plainly wrong — unlike the optional resets below.

### Pairs

| kind | computes | needs | key params |
|---|---|---|---|
| `:spread` | log spread `log_y - (β·log_x + α)`, z-scored | `value` (Y), `reference` (X) | `beta_mode`, `beta_window_ms` |

Owns **two** symbols: `symbol`/`source` for the Y leg,
`reference_symbol`/`reference_source` for X. `beta_mode` is
`"static"` (default — **requires `params["beta"]`**), `"rolling_ols"`, or
`"kalman"`.

`Compute.spread_extras/1` returns `%{beta:, alpha:, half_life:,
crossings:}`. **Check `half_life` and `crossings` before trading a
pair** — a spread that does not revert will still produce a
perfectly reasonable-looking z-score.

---

## Family 2: microstructure kinds

Also base kinds, but they read the **book** rather than a price series.
All were validated against live SPY ticks, not only unit tests.

| kind | computes | needs | key params |
|---|---|---|---|
| `:book_imbalance` | `(bid_size − ask_size) / (bid_size + ask_size)`, in `−1..1` | both sides **with sizes** | `max_quote_staleness_ms` |
| `:ofi` | order flow imbalance (Cont/Kukanov/Stoikov) | both sides **with sizes** | `window_ms` |
| `:quoted_spread` | `ask − bid`, or `/mid` | both sides | `relative` |
| `:effective_spread` | `2 × \|trade − mid\|` | both sides + a trade | `relative` |
| `:signed_volume` | buys minus sells over the window | trade price, `volume` | `classifier`, `window_ms` |
| `:kyle_lambda` | price impact: slope of mid return on signed volume | book + trades | `classifier`, `window_ms` |
| `:two_scale_rv` | noise-corrected realized variance | trade prices only | `subsample_mode`, `subsample_k` |

### What each is actually for

**`:book_imbalance`** — a strong 1–60 second directional predictor, and
the cheapest thing here. Positive means bid-side size dominates.

**`:ofi`** — the most-validated short-horizon predictor in the
literature, and it needs only L1. Per quote update: bid price rose →
`+new size`, unchanged → `+size delta`, fell → `−old size`. The ask side
mirrors with signs reversed, so an ask *falling* contributes
**positively** (sellers undercutting is buy-side pressure).

**`:quoted_spread` / `:effective_spread`** — a cost input *and* a
liquidity-regime feature; a widening spread is a tradeable state change.
Effective spread captures what a taker really paid: a print at 100.01
inside a 99.98/100.02 book costs `0.02` against a quoted `0.04`.

**`:signed_volume`** — complements `:ofi`: that measures quote
revisions, this measures executions. `classifier` is `"tick_rule"`
(default, needs no quotes) or `"lee_ready"` (compares to mid, falls back
to tick rule at mid or on a crossed book).

**`:kyle_lambda`** — price impact per unit of signed flow; **higher
means thinner liquidity**. A conditioning variable (size down when
impact is high), not a trade trigger.

**`:two_scale_rv`** — use this, not naive tick RV. Sampling faster makes
naive RV *worse* because every print carries bid-ask bounce: on a
simulated noisy walk it overstated true variance **9×** (1.49e-4 vs a
true 1.61e-5) where this recovered 1.57e-5. `subsample_mode` is
`"tick_count"` (default) or `"time"` — they are genuinely different
estimators on a thin name, so the choice is explicit and an unknown value
raises.

### Three things that will bite

**1. Feed quality decides whether `:ofi` means anything.** Measured
2026-09-21 on live SPY:

| | rate | gap p50 | both sides per msg | sizes |
|---|---|---|---|---|
| **Polygon WS** | **88–119/sec** | **0 ms** | **all** | yes |
| IBKR | 2.9/sec | 253 ms | none | yes |

IBKR is bucketed to ~250ms — a 4Hz sampler, not a quote stream. OFI
computed on it is a weaker statistic wearing the validated name, because
each observation is many collapsed revisions. **Use the Polygon WS feed**
(`TradingHub.Polygon.WebSocketClient`, topic `prices:polygon:SYMBOL`).
Note `TradingHub.MarketData.PolygonStreamer` is *not* a streamer — it is
a deprecated 15-second REST poller.

**1b. Distinguish trade from quote messages by `metadata.data_type`,
not by which keys are present.** On the Polygon WS feed both arrive as
`type: :price` and are tagged `:ws_trade`, `:ws_quote`, or
`:ws_aggregate` (`web_socket_client.ex:480/520/555`). Trades carry
`last` and no sizes; quotes carry `bid`/`ask`/`bid_size`/`ask_size` and
**no `last` key at all**.

That matters for any adapter translating this feed into ticks: matching
on `data: %{last: last}` silently drops every quote. Measured on a live
SPY capture, quotes were **1509 of 1940 messages — 77.8%** — so a
key-presence matcher discards the large majority of the feed with no
error anywhere. Match on the tag.

**2. Set `max_quote_staleness_ms` on any partial-update feed.** Pairing a
fresh bid against a minutes-old ask describes a book that existed at no
instant — and that failure is **silent**: valid arithmetic, an
ordinary-looking number, undetectable downstream. Unbounded is right only
for a snapshot feed where both sides share a timestamp.

**3. A near-zero or negative `:kyle_lambda` is a real reading.** On live
SPY over 60-second windows it sits around `−4e-7`: the mid mean-reverts
within the window and retail-size prints do not move the most liquid ETF
in the world. Read the magnitude; do not read the sign of a near-zero
slope as direction.

This generalises, and is worth stating plainly: **a signal being
uninformative on SPY is not evidence the signal is broken.** The most
liquid instrument available is the hardest place to measure impact,
reversion, or imbalance, precisely because it is efficient. Validate a
microstructure signal on something thinner before concluding it does not
work.

---

## Family 3: derived kinds

Wrap other nodes' emitted values rather than raw ticks. `replay/3`
resolves the DAG and feeds each child its parent's output.

### Single-parent

| kind | computes | key params |
|---|---|---|
| `:derivative` | rate of change of the parent | `window_ms` |
| `:second_derivative` | acceleration | `window_ms` |
| `:wavelet` | denoised parent series (DWT) | — |
| `:self_zscore` | parent standardized against its own window | `window_ms` |

### Dual-parent (`parent` vs. `reference`)

| kind | computes | key params |
|---|---|---|
| `:percent_deviation` | `(value − reference) / reference × 100` | — |
| `:ratio` | `value / reference` | — |
| `:zscore` | z-score of the spread between them | `window_ms`, `session_reset` |
| `:regime` | `−1 / 0 / +1` from a direction and a volatility gate | `tick_deadband`, `vix_gate_zscore` |

**`:regime`** takes a direction signal as `parent` and a volatility
z-score as `reference`. It emits `0` whenever the gate exceeds
`vix_gate_zscore` (default 1.5) — "too volatile, stand down" — and
otherwise `±1` by whether direction clears `±tick_deadband` (default
300).

**`:zscore`'s `session_reset` is opt-in and changes the signal's
meaning**, unlike `:vwap`'s. Enabling it makes the kind report
`:warming_up` around a session open where the unreset version reports a
number, so values either side of the switch are not comparable. Turn it
on when the reference is itself session-resetting (a `:vwap`), and record
the date you did.

---

## Cross-cutting rules

These hold for every kind, and exist because each was violated once:

- **`:warming_up`, never a wrong number.** Insufficient or degenerate
  input yields no value rather than a plausible one.
- **Degenerate inputs return nothing.** `zscore/2` has a *relative* stdev
  floor: a near-constant window emitting a confident z-score is worse
  than emitting nothing. (This shipped a `−11.49` reading on a closed
  Saturday tape before the floor existed.)
- **Unknown param values raise, they never default silently.** An
  unrecognised `beta_mode`, `classifier`, or `subsample_mode` fails at
  `init/1` — where the spec is built, not mid-stream in a live loop.
- **Pairing policy lives here, not in callers.** Which bid pairs with
  which ask, and which price legs pair for `:spread`, decide what the
  signal measures. If a caller did it, a live path and a replay path
  would compute different signals from identical data.
- **Zero is not the same as unknown.** `0/0` book depth, a locked book,
  and a missing size all return `:warming_up`, not `0.0`.

---

## Operational note: `trading_core` is a `path:` dependency

Consuming apps take this library as `path:`, which means **a running node
only picks up changes at compile + boot**. Editing here and expecting a
live node to see it does not work.

This has bitten the workspace at least twice: `TradingCore.Stats.bounds/4`
raising `UndefinedFunctionError` on a live node after the function was
merged, and a node running bytecode predating a day's signal work. Both
looked like "the code is wrong" and were actually "the node is old".

Check what a node actually has before debugging:

```elixir
:erpc.call(:"trading_signal@Scotts-Mac-mini.local",
           TradingCore.Signal.Spec, :kinds, [])
|> length()
```

If that disagrees with `Spec.kinds()` here, the node needs
`mix deps.compile trading_core --force` and a restart — not a code fix.

## Reference

- `MICROSTRUCTURE_SIGNALS_PLAN.md` — the phase plan, feed measurements,
  and per-phase prompts
- `trading_hub/MARKET_DATA_GUIDE.md` — how to subscribe to either feed
- `TradingCore.Signal.Compute` moduledoc — tick shape, warm-up, quote
  merging, session boundaries
- `TradingCore.Signals` — the underlying math, each function documenting
  the incident that shaped it
