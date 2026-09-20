# Microstructure signals — implementation plan

Six streaming microstructure signals for `TradingCore.Signal`: order flow
imbalance, top-of-book imbalance, signed volume, quoted/effective spread,
Kyle's lambda, and two-scale realized volatility.

All six are incremental and streaming, so they fit the existing
`Spec` → `init/1` → `step/2` → `replay/3` machinery. That part genuinely
is free. **The tick shape is not** — see phase 0.

Status: phase 0 in progress. Everything else is queued behind it.

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

## Phases, ordered by dependency

### Phase 0 — extend the tick *(prerequisite)*

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

### Phase 1 — `:book_imbalance`

`(bid_size − ask_size) / (bid_size + ask_size)`.

Stateless given a merged quote, so it is the cheapest real test of
whether phase 0's shape is right. **Build this first specifically to
validate the tick change** before four more kinds depend on it.

Returns `nil` (→ `:warming_up`) when either size is missing or the
denominator is zero.

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

### Phase 3 — `:quoted_spread` / `:effective_spread`

- **Quoted**: `ask − bid`, or relative to mid. Trivial from a merged
  quote.
- **Effective**: `2 × |trade_price − mid_at_execution|`. Needs the trade
  price *and* the prevailing mid at execution time. Check whether fills
  carry an as-of-quote timestamp; if not this is mid-at-nearest-tick,
  which should be documented as an approximation rather than hidden.

Both are a cost input *and* a liquidity-regime feature — a widening
spread is a tradeable state change, not just a fee.

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

### Phase 5 — `:kyle_lambda`

Rolling regression of mid return on signed volume. A direct price-impact
and liquidity measure, and a good conditioning variable.

Depends on phase 4's output. **`Signals.rolling_ols_beta/4` already
exists** from the `:spread` work and is exactly this shape — strong reuse
candidate rather than new regression code.

### Phase 6 — `:two_scale_rv`

Two-scale realized volatility (Zhang/Mykland/Aït-Sahalia).

**Independent of phases 0–5** — needs only trade prices, so it can run in
parallel. Naive tick-frequency RV is dominated by microstructure noise;
the noise-corrected estimator is the point.

Decide up front whether the slow scale is time-based or tick-count-based.
They diverge badly on thin names, and the choice should be explicit in
`params` rather than implicit in the implementation.

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
