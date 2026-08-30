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

  ## Commission: `commission/2`

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

  `large_position_notional_threshold` is a caller-supplied value (e.g.
  an app's own `AppSettings.large_position_notional_threshold`), passed
  in rather than fetched here — this module has no config/Repo
  dependency of any kind.
  """
  @spec simulate_fill_price(map(), String.t(), Decimal.t(), keyword()) :: Decimal.t()
  def simulate_fill_price(price_data, side, qty, opts) do
    slippage_bps = Keyword.fetch!(opts, :slippage_bps)
    threshold = Keyword.fetch!(opts, :large_position_notional_threshold)

    price_data = coerce_price_data(price_data)
    last = price_data[:last]
    base_slippage = base_slippage_amount(price_data, last, slippage_bps)
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

  # Real half-spread when both sides of the quote are available —
  # max(0, (ask - bid) / 2), since a crossed or zero-width quote should
  # never produce negative modeled slippage.
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
