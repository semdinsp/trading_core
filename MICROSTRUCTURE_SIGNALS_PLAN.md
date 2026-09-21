# Microstructure signals — implementation plan

Six streaming microstructure signals for `TradingCore.Signal`: order flow
imbalance, top-of-book imbalance, signed volume, quoted/effective spread,
Kyle's lambda, and two-scale realized volatility.

All six are incremental and streaming, so they fit the existing
`Spec` → `init/1` → `step/2` → `replay/3` machinery. That part genuinely
is free. **The tick shape is not** — see phase 0.

Status: **phases 0 and 1 complete** (merged).

**Phase 2 is BLOCKED** — not on rate (the Polygon WebSocket delivers 88
quotes/sec, measured), but on **bid/ask sizes being dropped** by
`trading_hub`'s WS quote handler. See "MEASURED, 2026-09-21" below.
Needs a one-line-ish fix in `trading_hub`, which is a sibling app this
repo must not edit — so it needs a handoff prompt.

Phases 3 and 6 are **not** blocked and can proceed today.

**Feed decision: Massive/Polygon quotes, not IBKR.** Confirmed by the
user 2026-09-20 — forcing the microstructure kinds onto a snapshot quote
feed is acceptable. That removes the partial-update merge problem
entirely (it becomes a no-op), supplies a real `quote_timestamp` for
honest effective spread, and is the only shape that makes OFI's
definition well-posed. The merge machinery from phase 0 stays regardless:
it costs nothing on a snapshot feed and keeps the IBKR path correct if
anything ever uses it.

---

## The blocker: the tick cannot carry quote data

`TradingCore.Signal.Compute`'s tick type today:

```elixir
@type tick :: %{
        required(:at) => DateTime.t(),
        required(:value) => Signals.sample() | nil,
        optional(:volume) => Signals.sample() | nil
      }
```

No bid, ask, bid size, ask size, or trade price distinct from `:value`.
Four of the six signals need data this type cannot express, so a tick
extension is the prerequisite for everything except two-scale RV.

### MEASURED, 2026-09-21 — read this before phase 2

Live measurement of SPY during market hours, three feeds compared. This
supersedes the speculation in the section below, and changes what phase 2
can be built on.

| | IBKR (`prices:SPY`) | Polygon **WS** (`prices:polygon:SPY`) | Polygon `PolygonStreamer` |
|---|---|---|---|
| Rate | 2.9 quotes/sec | **88.3 quotes/sec** | ~1 per 12s |
| Quote gap p50 | **253 ms** (throttled) | **0 ms** (p90 = 11 ms) | 15 s |
| Both sides per message | **0 of 111** | **2650 of 2650** | n/a |
| **Bid/ask sizes** | **yes** | **NO — dropped** | yes |

Three conclusions:

1. **IBKR is a 4Hz sampler, not a quote stream.** The gap histogram is
   quantized — a spike at 0 ms, then mass at 200–250 ms, nothing below.
   That is IBKR's standard snapshot bucket. OFI computed on it would be
   OFI over a sampled book.
2. **`TradingHub.MarketData.PolygonStreamer` is not a streamer.** Despite
   the name it polls REST every 15 s through a 5-calls/60-s budget, and
   is explicitly marked deprecated in
   `trading_hub/MARKET_DATA_GUIDE.md`. The flag
   `:polygon_streaming_enabled` belongs to *it*, not to the WebSocket —
   checking that flag to answer "is Polygon streaming up?" gives the
   wrong answer, which the guide warns about and which this measurement
   initially got wrong.
3. **`TradingHub.Polygon.WebSocketClient` is the real thing** and is
   already enabled (`:polygon_ws_enabled` = true) and running. 88
   quotes/sec, both sides on every message, sub-millisecond median gap.
   This is a genuine tick-level quote feed and OFI is well-posed on it.

**The one blocker: sizes are dropped in translation.** Polygon's `Q`
event carries `"bs"`/`"as"` (bid and ask size), but
`web_socket_client.ex:480`'s `broadcast_quote/1` pattern-matches only
`"bp"`/`"ap"` and publishes `%{bid:, ask:, timestamp:}`. So the feed with
the right *rate* currently lacks the sizes, and the feeds with sizes have
the wrong rate.

Every size-dependent signal is blocked on that: **`:book_imbalance`
(phase 1, already built), `:ofi` (phase 2)**. Not blocked:
`:quoted_spread` (phase 3, prices only), `:two_scale_rv` (phase 6, trades
only).

**`trading_hub` is a sibling app — this repo must not edit it.** The fix
is to add `"bs"`/`"as"` to that pattern match and include `bid_size`/
`ask_size` in the broadcast payload, which needs a handoff prompt to
`trading_hub`'s own session. Until then, phase 1 runs correctly against
IBKR's sized-but-slow feed and phase 2 should not be started.

To reproduce: subscribe via
`TradingHub.Polygon.WebSocketClient.subscribe_symbol("SPY", "your_tag")`
then listen on `TradingContract.Topics.prices_polygon("SPY")`. See
`trading_hub/MARKET_DATA_GUIDE.md`.

### Provider shapes differ, and it matters

| | IBKR (`trading_hub`) | Polygon / Massive |
|---|---|---|
| Quote delivery | **One side at a time** — `%{bid:, bid_size:}`, then separately `%{ask:, ask_size:}` (`ibkr_provider.ex:139`, `message_handler.ex:88-89`) | **All four fields in one snapshot** (`polygon/client.ex:625-628`) |
| Quote timestamp | Not carried | `quote_timestamp` |
| Trade timestamp | Not carried | `trade_timestamp` |

This is the strongest argument for moving these signals to
Massive/Polygon rather than IBKR:

1. **One-sided updates make the merge policy load-bearing.** OFI compares
   *both* sides against their previous state on every update. Whoever
   pairs a bid-only tick with the last known ask decides what the signal
   measures. That is the same problem `:spread`'s leg pairing had (PR
   #32), and it needs the same answer: `Compute` merges, so live and
   replay compute the same thing. With a Polygon snapshot the merge is a
   no-op, and the question disappears.
2. **A separate quote timestamp is required for honest effective
   spread.** Effective spread is `2 × |trade_price − mid_at_execution|`.
   Without a quote timestamp, "the prevailing mid" is whatever the last
   merged quote happened to be, which is an approximation. Polygon
   carries `quote_timestamp`, so the approximation can be measured rather
   than assumed.
3. **Sampled quotes are not the estimator the literature validates.** OFI
   is only as good as the quote update rate. If ticks are throttled or
   coalesced anywhere in the path, the result is OFI over a sampled book
   — a different, weaker statistic wearing the same name. **Verify the
   real arrival rate for one symbol before trusting phase 2.**

---

## How to use the prompts below

Each phase carries a **Prompt** block: paste it into a session scoped to
`trading_core/` and it is executable as-is. They assume the reader has
not read this document, so each repeats what it needs — but read "The
blocker" above first if you are touching phases 1–5, because the quote
merge is the thing most likely to be reimplemented by mistake.

Phases are **sequential**, not parallel: 1 proves the tick shape, 2–5
each build on the one before, and only 6 is independent. Do not start a
phase whose predecessor has not merged.

Every prompt ends at the same bar: `mix test` green,
`mix compile --warnings-as-errors` clean, no new deps, branch pushed.

---

## Phases, ordered by dependency

### Phase 0 — extend the tick *(prerequisite)* — **DONE**

Merged as `1832e59`. `new_quote_state/0`, `merge_quote/3` and
`quote_ready?/2` are on `main`; the tick carries optional
`:bid`/`:ask`/`:bid_size`/`:ask_size`, and every existing kind is
provably unaffected.

Add optional quote fields to the tick type, and merge one-sided updates
inside `Compute` rather than pushing that onto every caller.

- Optional `:bid`, `:ask`, `:bid_size`, `:ask_size` on the tick.
- Last-known-of-each merging for one-sided quote updates, reusing the
  `merge_spread_legs/3` / `put_leg/5` pattern from `:spread`.
- A staleness bound, same reasoning as `max_leg_staleness_ms`: pairing a
  fresh bid against a stale ask reports a book that never existed. For a
  snapshot provider the legs always share a timestamp, so the bound never
  bites — it exists for the IBKR path.
- Additive only. Existing kinds ignore the new fields; existing callers
  are unaffected.

**Deliberately NOT adding `:trade_side` to the tick.** Classifying a
print as buyer- or seller-initiated (tick rule, Lee-Ready) is a
*computation*, not an input. If the caller supplies the side, the
signal's logic has moved into the caller and replay equivalence is lost —
the same mistake as caller-side leg pairing. The tick carries trade price
and size; the kind classifies.

### Phase 1 — `:book_imbalance` — **DONE**

`(bid_size − ask_size) / (bid_size + ask_size)`.

Stateless given a merged quote, so it is the cheapest real test of
whether phase 0's shape is right. **Build this first specifically to
validate the tick change** before four more kinds depend on it.

Returns `nil` (→ `:warming_up`) when either size is missing or the
denominator is zero.

> **Prompt — phase 1**
>
> In `trading_core/`, add a `:book_imbalance` signal kind.
>
> **What it computes:** `(bid_size - ask_size) / (bid_size + ask_size)`,
> from the merged top of book. Range `-1.0`..`1.0`; positive means bid-side
> size dominates. Stateless apart from the book state itself.
>
> **Use the existing quote machinery — do not reimplement it.**
> `TradingCore.Signal.Compute` already has `new_quote_state/0`,
> `merge_quote/3` and `quote_ready?/2` (added in phase 0, `1832e59`). The
> tick carries optional `:bid`, `:ask`, `:bid_size`, `:ask_size`, and may
> carry **one side only** — `merge_quote/3` holds the other. That merge
> decides which bid is paired with which ask, which is what this signal
> measures, so it must stay in `Compute`.
>
> **Add:**
> - `:book_imbalance` to `Spec`'s `@base_kinds` and the `kind()` type. It
>   is base-like: it owns its own feed, wraps no parent node.
> - `init/1` returning `%{quote: Compute.new_quote_state()}`.
> - A `step/2` clause: merge the tick, then
>   `quote_ready?(state.quote, max_quote_staleness_ms)`; when ready compute
>   the ratio, else `:warming_up`. Read the bound from
>   `params["max_quote_staleness_ms"]`, defaulting to `nil` (unbounded).
>
> **Edge cases that must return `nil` → `:warming_up`, not a number:**
> - either side unknown (book not yet complete)
> - either size missing (a price can arrive without a size)
> - `bid_size + ask_size == 0` — zero total depth is not a balanced book,
>   it is no book at all, and `0/0` must not become `0.0`
>
> Use `Decimal` throughout, matching the other kinds. Round to
> `params["precision"]` if present, as `window_opts/1` already does
> elsewhere.
>
> **Tests:** assert exact values for a bid-heavy, ask-heavy and balanced
> book; both boundary values (`-1.0` when bid size is 0, `1.0` when ask
> size is 0); every `:warming_up` case above, each separately; that a
> one-sided tick sequence (IBKR's `%{bid:, bid_size:}` then `%{ask:,
> ask_size:}`) completes the book and emits; and that the staleness bound
> rejects a stale pairing.
>
> **Done when:** `mix test` green, `mix compile --warnings-as-errors`
> clean, no new deps, pushed on `claude/book-imbalance`.

### Phase 2 — `:ofi` (order flow imbalance)

Cont/Kukanov/Stoikov. Per quote update: add bid size change when the bid
price rises or holds, subtract bid size when it falls; mirror on the ask;
sum over a window.

- State carries previous bid/ask price *and* size.
- Needs only L1.
- The highest-value item here, and the most sensitive to phase 0's merge
  policy — a mis-paired update does not error, it silently produces a
  wrong number.
- Verify quote arrival rate before trusting output (see above).

> **Prompt — for `trading_hub`'s session (unblocks phase 2)**
>
> In `trading_hub/`, include bid and ask **sizes** in the Polygon
> WebSocket quote broadcast.
>
> `lib/trading_hub/polygon/web_socket_client.ex:480`'s `broadcast_quote/1`
> currently matches only the prices:
>
> ```elixir
> defp broadcast_quote(%{"sym" => symbol, "bp" => bid, "ap" => ask, "t" => timestamp_ms}) do
> ```
>
> Polygon's `Q` event also carries `"bs"` (bid size) and `"as"` (ask
> size). Add them to the match and to the broadcast `data` map as
> `bid_size`/`ask_size`, converted the same way the prices are.
>
> **Why:** `trading_core`'s microstructure kinds — `:book_imbalance`
> (built) and `:ofi` (blocked on this) — compute
> `(bid_size - ask_size) / (bid_size + ask_size)` and per-update size
> deltas. Measured 2026-09-21: the Polygon WS feed delivers 88
> quotes/sec with both sides on every message, which is exactly the rate
> those signals need, but the sizes are dropped here so they cannot be
> computed from it. IBKR's feed carries sizes but is throttled to ~250 ms,
> which is too coarse for order-flow imbalance.
>
> **Keep it additive.** Existing consumers match on `:bid`/`:ask`; adding
> keys must not change what they see. Match sizes as optional if a `Q`
> event can ever omit them, rather than letting a sizeless quote fall
> through to the `broadcast_quote(_quote), do: :ok` catch-all and silently
> stop publishing quotes.
>
> Worth updating `MARKET_DATA_GUIDE.md`'s quote-shape example too — it
> documents `%{bid:, ask:, timestamp:}`.

> **Prompt — phase 2**
>
> In `trading_core/`, add an `:ofi` (order flow imbalance) kind,
> Cont/Kukanov/Stoikov. Phase 1 must have merged first.
>
> **Per quote update**, comparing against the previous book:
> - bid price **rose**: add the new bid size
> - bid price **unchanged**: add the *change* in bid size
> - bid price **fell**: subtract the old bid size
> - ask side mirrors with the signs reversed (ask price falling is
>   buy-side pressure)
>
> Sum those contributions over `window_ms`. Reuse
> `TradingCore.Signals.trim_window/3`'s pattern for the rolling sum
> rather than writing new window code, and use the phase 0 quote
> machinery for the book.
>
> **State** must carry the previous bid price *and* size and ask price
> *and* size — the deltas are meaningless without both. First tick after
> init has no previous book, so it contributes nothing and returns
> `:warming_up`.
>
> **Read the "Provider shapes differ" section of this plan before
> starting.** OFI is the signal most sensitive to the merge policy: a
> mis-paired update does not raise, it silently produces a wrong number.
> Confirm the live quote arrival rate first — OFI over a throttled or
> coalesced feed is a different, weaker statistic wearing the validated
> name.
>
> **Tests:** each of the six price-direction cases separately with
> hand-computed contributions; a full window summing several updates;
> first-tick-after-init returning `:warming_up`; and a window rolling
> off old contributions.
>
> **Done when:** the standard bar, pushed on `claude/ofi`.

### Phase 3 — `:quoted_spread` / `:effective_spread` — **DONE**

- **Quoted**: `ask − bid`, or relative to mid. Trivial from a merged
  quote.
- **Effective**: `2 × |trade_price − mid_at_execution|`. Needs the trade
  price *and* the prevailing mid at execution time. Check whether fills
  carry an as-of-quote timestamp; if not this is mid-at-nearest-tick,
  which should be documented as an approximation rather than hidden.

Both are a cost input *and* a liquidity-regime feature — a widening
spread is a tradeable state change, not just a fee.

> **Prompt — phase 3**
>
> In `trading_core/`, add `:quoted_spread` and `:effective_spread` kinds.
>
> - **`:quoted_spread`** — `ask - bid`, or `(ask - bid) / mid` when
>   `params["relative"]` is true. Straight off the phase 0 quote state.
> - **`:effective_spread`** — `2 * abs(trade_price - mid_at_execution)`,
>   again relative to mid when asked.
>
> **The honesty problem, which must be documented rather than hidden:**
> effective spread needs the mid *prevailing at execution*. On a snapshot
> feed carrying `quote_timestamp` that is a real lookup. Without one it
> degrades to mid-at-last-merged-quote, which is an approximation. Say so
> in the moduledoc and name the condition under which it is exact; do not
> let a caller assume precision the data does not support.
>
> Return `:warming_up` when the book is incomplete, and when a crossed or
> locked book would make the spread negative or zero — a negative spread
> is bad data, not a tradeable signal.
>
> **Tests:** absolute and relative forms for both kinds; a crossed book
> returning `:warming_up`; effective spread against a known trade and
> mid; incomplete book cases.
>
> **Done when:** the standard bar, pushed on `claude/spread-measures`.

### Phase 4 — `:signed_volume`

Tick-rule or Lee-Ready classification of each print, then netted.

- **Tick rule first**: needs only the prior trade price. Cheap, no
  dependency on quote data.
- **Lee-Ready second**: compares trade price to the prevailing mid, so it
  depends on phase 0.
- Ship as one kind with a `classifier` param (`"tick_rule"` /
  `"lee_ready"`), mirroring `:spread`'s `beta_mode`, rather than two
  kinds.

Complements OFI: executions versus quote revisions.

> **Prompt — phase 4**
>
> In `trading_core/`, add a `:signed_volume` kind netting
> buyer-initiated against seller-initiated volume over a window.
>
> One kind, with `params["classifier"]`:
> - **`"tick_rule"`** (default) — sign from the trade price against the
>   *previous trade price*: higher → buy, lower → sell, equal → carry the
>   previous sign forward. Needs no quote data.
> - **`"lee_ready"`** — trade above mid → buy, below → sell, exactly at
>   mid → fall back to the tick rule. Needs the phase 0 quote state.
>
> Mirror `:spread`'s `beta_mode` dispatch: one clause per classifier,
> **raise on an unrecognised value** rather than defaulting silently.
>
> **Do not accept a caller-supplied trade side.** Classification is the
> computation this kind exists to perform; taking it as input moves the
> logic into the caller and loses replay equivalence. The tick carries
> trade price and size; this kind decides the sign.
>
> First trade has no predecessor and no carried sign, so it contributes
> nothing and returns `:warming_up`.
>
> **Tests:** each classifier separately; the equal-price carry-forward;
> `lee_ready`'s at-mid fallback to tick rule; an unrecognised classifier
> raising; first-trade `:warming_up`; window roll-off.
>
> **Done when:** the standard bar, pushed on `claude/signed-volume`.

### Phase 5 — `:kyle_lambda`

Rolling regression of mid return on signed volume. A direct price-impact
and liquidity measure, and a good conditioning variable.

Depends on phase 4's output. **`Signals.rolling_ols_beta/4` already
exists** from the `:spread` work and is exactly this shape — strong reuse
candidate rather than new regression code.

> **Prompt — phase 5**
>
> In `trading_core/`, add a `:kyle_lambda` kind: the rolling regression
> slope of mid return on signed volume. Phase 4 must have merged.
>
> **Reuse `TradingCore.Signals.rolling_ols_beta/4`.** It already fits a
> rolling OLS over a `{x, y}` window and returns `{beta, alpha}` — do not
> write a second regression. Here `x` is signed volume over the interval
> and `y` is the mid return over the same interval.
>
> Lambda is the slope: higher means a given signed volume moves price
> further, i.e. thinner liquidity. Emitting it is the point; it is a
> conditioning variable, not a trade trigger.
>
> **Guard the degenerate case.** A window with no variation in signed
> volume gives a meaningless or explosive slope — `rolling_ols_beta/4`
> should already return `nil` there, but assert it rather than assume it,
> the same way `Signals.zscore/2`'s relative stdev floor exists because a
> near-constant window emitting a confident number is worse than emitting
> nothing.
>
> **Tests:** a hand-computed slope on a known series; a flat signed-volume
> window returning `:warming_up`; insufficient samples; window roll-off.
>
> **Done when:** the standard bar, pushed on `claude/kyle-lambda`.

### Phase 6 — `:two_scale_rv` — **DONE**

Two-scale realized volatility (Zhang/Mykland/Aït-Sahalia).

**Independent of phases 0–5** — needs only trade prices, so it can run in
parallel. Naive tick-frequency RV is dominated by microstructure noise;
the noise-corrected estimator is the point.

Decide up front whether the slow scale is time-based or tick-count-based.
They diverge badly on thin names, and the choice should be explicit in
`params` rather than implicit in the implementation.

> **Prompt — phase 6**
>
> In `trading_core/`, add a `:two_scale_rv` kind: noise-corrected
> realized volatility (Zhang/Mykland/Aït-Sahalia).
>
> **Independent of phases 1–5** — it needs only trade prices, so it can be
> built any time, including before them.
>
> Naive tick-frequency RV is dominated by microstructure noise: sampling
> faster makes the estimate *worse*, not better, because each print
> carries bid-ask bounce. The two-scale estimator computes RV on a fast
> scale and a slow (subsampled) scale and combines them to cancel the
> noise term. Shipping naive tick RV instead is the failure this phase
> exists to avoid.
>
> **Make the slow scale explicit in `params`**, not implicit: a
> tick-count subsample and a time-based subsample give materially
> different answers on a thin name, and the caller must choose. Raise on
> an unrecognised mode rather than defaulting silently.
>
> Return `:warming_up` until the slow scale has enough samples to be
> estimable at all.
>
> **Tests:** the estimator against a hand-computed value on a short
> series; both subsample modes on the same input, asserting they differ;
> an unrecognised mode raising; insufficient-sample cases. A property
> test that the corrected estimate is not systematically larger than
> naive RV on a noisy series would be worth having.
>
> **Done when:** the standard bar, pushed on `claude/two-scale-rv`.

---

## Conventions these must follow

Established by the existing kinds, and non-negotiable for new ones:

- **Purity.** No GenServer, no PubSub, no Repo, no side effects.
  `trading_core` stays free of Phoenix and Ecto.
- **Replay equivalence.** Anything that changes *which inputs get paired*
  belongs in `Compute`, not in a caller. This is the whole reason the
  library exists.
- **No silent fallbacks.** Insufficient data returns `nil` →
  `:warming_up`. An unrecognised param raises rather than quietly
  defaulting — see `:spread`'s `:tiered` clause and `UI.Tokens`' absent
  catch-all.
- **Degenerate inputs return `nil`, not a number.** See
  `Signals.zscore/2`'s relative stdev floor: a near-constant window
  emitting a confident z-score is worse than emitting nothing.
- **Document the rationale, not just the behaviour.** A constraint with
  no recorded reason is indistinguishable from a deliberate one when
  someone later wants to relax it.
