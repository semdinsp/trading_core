defmodule TradingCore.CostModel do
  @moduledoc """
  Models the two real trading costs simulated (paper) fills have always
  ignored: fill slippage and commission — Part 4 of the entry/exit
  reporting spec. Both are pure functions, deliberately Ecto-free and
  free of any app-specific state/config (same convention
  `TradingCore.PositionSizing` already follows — see that module's own
  moduledoc), so a caller supplies whatever market data and settings it
  has in hand rather than this module fetching or configuring anything
  itself.

  Extracted from `TradingLive.CostModel` (formerly duplicated
  field-for-field in `trading_system` as `TradingSystem.Trading.CostModel`)
  into this shared library, same "one place to fix, not two copies that
  can silently drift apart" reasoning `TradingCore.PositionSizing`'s own
  moduledoc gives — confirmed necessary here: at extraction time the two
  existing copies had already drifted (see `simulate_fill_price/4`'s own
  doc for the float-coercion fix `trading_system`'s copy was missing).
  `trading_live` now delegates to this module via its own thin
  `TradingLive.CostModel` wrapper rather than calling this module
  directly from call sites, so a future consumer (`trading_backtest`,
  for computing breakeven round-trip costs on a signal-backtest feature)
  can depend on this module alone, with no `trading_live`-specific
  wrapper in the way.

  Before this module existed, `TradingLive.IBKR.Client.simulate_fill/1`
  (and `trading_system`'s `EntryExecutionWorker.simulate_paper_fill/2` /
  `CloseRunWorker.fill_orders/3`) set the fill price to the exact
  reference tick with zero modeling — every paper round trip was
  systematically better than a real fill could ever be. Per the spec's
  own framing: "every sub-0.2% round trip in the current data is very
  likely negative once charged."

  ## Slippage: `simulate_fill_price/4`

  Half-spread at minimum — a market order realistically fills at (or
  worse than) the near side of the quoted spread, not at the midpoint/last
  tick a caller might otherwise assume. Falls back to a flat-bps estimate
  (a caller-supplied `slippage_bps`, typically an app's own
  `AppSettings.estimated_slippage_bps_northamerica`/`_asia`) when a real
  bid/ask isn't available — a caller's market-data source may not
  guarantee both sides are populated (thin names, outside market hours,
  or the RPC itself failing) — "no spread data" must never mean "model
  zero cost."

  Also applies a size-aware impact multiplier on top of the half-spread
  when a position's notional exceeds a caller-supplied
  `large_position_notional_threshold` — a crude proxy, not a real
  ADV-based model: no consumer of this module has an ADV/volume figure
  plumbed in today. The proxy scales impact linearly with how far over
  the threshold the position's notional sits, capped at
  `@max_impact_multiplier`× the base half-spread, so it degrades
  gracefully rather than blowing up on an extreme outlier.

  ## The bad-quote guard: `:max_spread_bps`

  Ported from `trading_system`'s copy (added there 2026-10-01) so both
  apps fill paper orders with one model. `trading_hub`'s bid/ask was
  often stale or tens to hundreds of bps wide (WFC 79.01/80.69 against a
  ~1c real spread); a half-spread fill on such a quote, doubled by the
  impact multiplier on a standard $55K position, was most of several
  losing days' paper P&L. With `:max_spread_bps` set, a quote is used
  only when `last` lies inside `[bid, ask]` and the spread is no wider
  than `max_spread_bps` of `last`; otherwise bid/ask are dropped and the
  flat `slippage_bps` fallback applies. Off unless the caller passes it;
  `max_spread_bps_for/1` gives the value for an asset class (equities
  only, since an option premium is legitimately quoted wide).

  ## Commission: `order_commission/4` (and the superseded `commission/2`)

  `order_commission/4` is IBKR's real per-**order** cost, base plus the
  regulatory fees IBKR bills, via `TradingCore.Costs.IBKR.order_cost/4`
  for stocks and `option_cost/3` for options (`multiplier` other than 1).
  It is what `trading_live` and `trading_system` both use.

  `commission/2` below is the original per-**fill** Fixed estimate with
  no regulatory fees. Reverse-engineered real IBKR fills showed it
  overcharges by 14-98% (IBKR bills per order), so both apps moved off
  it; it is kept only for existing callers and should not be used for
  new code.

  Models IBKR Pro's **Fixed** pricing schedule for US stocks/ETFs — flat
  \\$0.005/share, a \\$1.00 minimum per order, capped at 1% of trade
  value. (IBKR also offers **Tiered** pricing, cheaper per-share but
  volume-tiered against trailing 30-day activity — not modeled here since
  it requires tracking rolling volume no consumer of this module has a
  use for otherwise, and Fixed is the simpler, tier-free default most
  small/personal accounts are on. If the actual IBKR account a consumer
  trades through is on Tiered, this constant needs updating, not a
  structural change.) At small test sizes (the spec's own 1-share
  example) the \\$1.00 minimum dominates and can exceed the entire
  trade's gross P&L outright — exactly the case this function exists to
  make visible instead of invisible.

  ## What this module does NOT do

  Never intended for a **live** fill's commission — Part 4 also requires
  taking the real commission from IBKR's `commissionReport` callback for
  live fills, not modelling one; that plumbing (or the lack of it) is
  each consumer app's own concern, not this module's.
  """

  @commission_per_share Decimal.new("0.005")
  @commission_minimum Decimal.new("1.00")
  @commission_max_pct_of_trade_value Decimal.new("0.01")

  @max_impact_multiplier Decimal.new("3")

  # A quote wider than this, in bps of `last`, is treated as bad data
  # rather than a real spread; see "The bad-quote guard" above. Every name
  # traded is a liquid US large cap or ETF quoted a cent or two wide.
  @equity_max_spread_bps 25

  @doc """
  The `:max_spread_bps` guard to pass `simulate_fill_price/4` for an
  instrument's `asset_class`: #{@equity_max_spread_bps} for `"equity"`,
  `nil` (no guard) for anything else, since option premiums are quoted
  legitimately wide.
  """
  @spec max_spread_bps_for(String.t() | nil) :: pos_integer() | nil
  def max_spread_bps_for("equity"), do: @equity_max_spread_bps
  def max_spread_bps_for(_asset_class), do: nil

  @doc """
  The simulated fill price for a paper order of `qty` shares on `side`
  (`"buy"` or `"sell"`), given `price_data` (a `%{bid:, ask:, last:}`
  map — values may be `Decimal`, float, or integer, see below) and
  `slippage_bps` (the caller's region-appropriate flat-slippage
  fallback).

  A market buy realistically fills at or above the ask (the near/worse
  side for a buyer); a market sell fills at or below the bid. When both
  `bid`/`ask` are present, slippage is `max(half-spread, size-aware
  floor)` applied against `last` in the adverse direction — i.e. always
  at least the real half-spread, never less, with the notional-based
  impact multiplier (see this module's own doc) added on top when the
  position is large enough to matter. When `bid`/`ask` is missing
  (`nil`), falls back to the flat `slippage_bps` estimate applied to
  `last` the same adverse-direction way, rather than filling at the
  unmodified reference price.

  `price_data`'s `:bid`/`:ask`/`:last` values are coerced to `Decimal`
  before any arithmetic — a real-world market-data feed (confirmed with
  IBKR tick data via `trading_hub`'s `MarketData.Manager.get_last_price/1`)
  can hand back native floats rather than `Decimal`, and `Decimal.sub/2`
  et al. raise `ArgumentError` on a bare float rather than converting it.
  This crashed every live-price entry attempt before the coercion was
  added — callers never need to coerce `price_data` themselves.

  The same fallback applies when the quote looks bad and
  `opts[:max_spread_bps]` is set: `last` outside `[bid, ask]` (stale or
  crossed), or a spread wider than `max_spread_bps` of `last`. Without the
  option the guard is off; `max_spread_bps_for/1` gives the value. See
  "The bad-quote guard" in the moduledoc.

  `large_position_notional_threshold` is a caller-supplied value (e.g.
  an app's own `AppSettings.large_position_notional_threshold`), passed
  in rather than fetched here — this module has no config/Repo
  dependency of any kind.
  """
  @spec simulate_fill_price(map(), String.t(), Decimal.t(), keyword()) :: Decimal.t()
  def simulate_fill_price(price_data, side, qty, opts) do
    slippage_bps = Keyword.fetch!(opts, :slippage_bps)
    threshold = Keyword.fetch!(opts, :large_position_notional_threshold)

    max_spread_bps = Keyword.get(opts, :max_spread_bps)

    price_data = coerce_price_data(price_data)
    last = price_data[:last]

    base_slippage =
      price_data
      |> usable_quote(last, max_spread_bps)
      |> base_slippage_amount(last, slippage_bps)

    impact_multiplier = impact_multiplier(last, qty, threshold)

    total_slippage = Decimal.mult(base_slippage, impact_multiplier)

    case side do
      "buy" -> Decimal.add(last, total_slippage)
      "sell" -> Decimal.sub(last, total_slippage)
    end
  end

  defp coerce_price_data(price_data) do
    price_data
    |> Map.put(:bid, to_decimal(price_data[:bid]))
    |> Map.put(:ask, to_decimal(price_data[:ask]))
    |> Map.put(:last, to_decimal(price_data[:last]))
  end

  defp to_decimal(nil), do: nil
  defp to_decimal(%Decimal{} = value), do: value
  defp to_decimal(value) when is_float(value), do: Decimal.from_float(value)
  defp to_decimal(value) when is_integer(value), do: Decimal.new(value)

  # Keeps bid/ask only when they look like a real quote: last inside
  # [bid, ask] and the spread no wider than max_spread_bps of last. A stale
  # quote (last outside it, or crossed) or an implausibly wide one is
  # dropped, which sends base_slippage_amount/3 to the flat-bps fallback.
  # Identical to trading_system's usable_quote/3 (2026-10-01).
  defp usable_quote(price_data, _last, nil), do: price_data

  defp usable_quote(%{bid: bid, ask: ask} = price_data, last, max_spread_bps)
       when not is_nil(bid) and not is_nil(ask) and not is_nil(last) do
    spread = Decimal.sub(ask, bid)
    max_spread = last |> Decimal.mult(max_spread_bps) |> Decimal.div(10_000)

    inside? =
      Decimal.compare(last, bid) != :lt and Decimal.compare(last, ask) != :gt

    if inside? and Decimal.compare(spread, max_spread) != :gt do
      price_data
    else
      %{price_data | bid: nil, ask: nil}
    end
  end

  defp usable_quote(price_data, _last, _max_spread_bps), do: price_data

  # Real half-spread when both sides of the quote are available —
  # max(0, (ask - bid) / 2), since a crossed or zero-width quote should
  # never produce negative modeled slippage (kept as a floor even though
  # usable_quote/3 drops crossed quotes when the guard is on).
  defp base_slippage_amount(%{bid: bid, ask: ask}, _last, _slippage_bps)
       when not is_nil(bid) and not is_nil(ask) do
    half_spread = ask |> Decimal.sub(bid) |> Decimal.div(2)
    Decimal.max(half_spread, Decimal.new(0))
  end

  # Fallback: the flat bps estimate against last, applied to the fill
  # instead of just estimated after the fact.
  defp base_slippage_amount(_price_data, last, slippage_bps) do
    last |> Decimal.mult(slippage_bps) |> Decimal.div(10_000)
  end

  # 1.0x below the threshold (no extra impact); scales linearly above it,
  # capped at @max_impact_multiplier so one extreme outlier position
  # can't blow the model up unboundedly. This is a crude notional-based
  # proxy for real market impact, not a real ADV-relative model — see
  # this module's own doc for why.
  defp impact_multiplier(_last, _qty, nil), do: Decimal.new(1)

  defp impact_multiplier(last, qty, threshold) do
    notional = Decimal.mult(last, qty)

    if Decimal.gt?(notional, threshold) and Decimal.gt?(threshold, 0) do
      ratio = Decimal.div(notional, threshold)
      Decimal.min(ratio, @max_impact_multiplier)
    else
      Decimal.new(1)
    end
  end

  @doc """
  IBKR's real per-order commission (base plus regulatory fees) for an
  order of `quantity` at `price` on `side` (`"buy"`/`"sell"`).

  With `multiplier` 1 (the default) it is a stock order:
  `TradingCore.Costs.IBKR.order_cost/4` on notional `quantity * price`.
  Otherwise it is an option order: `quantity` is the contract count and
  the notional is `quantity * price * multiplier`, priced by
  `TradingCore.Costs.IBKR.option_cost/3` (the per-contract schedule; the
  notional only feeds the SEC fee on sells).

  The same function as `trading_live`'s `TradingLive.CostModel.order_commission/4`
  and, for stocks, `trading_system`'s `order_commission/3`, so both can
  delegate here.
  """
  @spec order_commission(Decimal.t(), Decimal.t(), String.t(), Decimal.t()) :: Decimal.t()
  def order_commission(quantity, price, side, multiplier \\ Decimal.new(1)) do
    if Decimal.equal?(multiplier, 1) do
      TradingCore.Costs.IBKR.order_cost(quantity, Decimal.mult(quantity, price), side_atom(side))
    else
      notional = quantity |> Decimal.mult(price) |> Decimal.mult(multiplier)
      TradingCore.Costs.IBKR.option_cost(quantity, notional, side_atom(side))
    end
  end

  defp side_atom("buy"), do: :buy
  defp side_atom("sell"), do: :sell

  @doc """
  **Superseded by `order_commission/4`** — overcharges by 14-98% because it
  charges the minimum per fill and omits regulatory fees; kept for
  existing callers only. See "Commission" in the moduledoc.

  IBKR Pro Fixed commission for one order of `qty` shares at `fill_price`
  — `max(qty * $0.005, $1.00)`, capped at 1% of trade value. See this
  module's own doc for why Fixed (not Tiered) is modeled, and why the
  minimum matters: at a 1-share test size, `qty * $0.005` is a fraction
  of a cent, so the `$1.00` minimum is what actually applies — often
  exceeding the entire trade's gross P&L outright.
  """
  @spec commission(Decimal.t(), Decimal.t()) :: Decimal.t()
  def commission(qty, fill_price) do
    per_share_cost = Decimal.mult(qty, @commission_per_share)
    base_commission = Decimal.max(per_share_cost, @commission_minimum)

    trade_value = Decimal.mult(qty, fill_price)
    max_commission = Decimal.mult(trade_value, @commission_max_pct_of_trade_value)

    Decimal.min(base_commission, max_commission)
  end
end
