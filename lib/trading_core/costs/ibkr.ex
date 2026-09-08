defmodule TradingCore.Costs.IBKR do
  @moduledoc """
  US equity commission per IBKR's published schedule.

  Charged PER ORDER, not per fill — an order filled in N executions pays
  one minimum. Callers must group fills by `broker_order_id` before
  calling `order_cost/4`.

  Rates verified against
  interactivebrokers.com/en/pricing/commissions-stocks.php on 2026-09-08.
  The SEC transaction fee rate resets annually (and mid-year when the SEC
  adjusts it) — re-read the page and update `@sec_rate` rather than
  assuming it is stable.

  `trading_core`'s existing `TradingCore.CostModel.commission/2` models
  IBKR Pro Fixed pricing per **fill** (not per order) and omits
  third-party fees entirely — reverse-engineered from
  `realized_pnl`/`realized_pnl_net` and confirmed to overcharge small
  test trades by 14-98% against real IBKR fills. This module is the
  corrected replacement; wiring callers over to it is each app's own
  follow-up, not done here.
  """

  # :fixed | :tiered — CONFIRM in Account Management → Settings → Account
  # Configuration → Fee Structure before trusting this default. Two
  # independent strategies' real IBKR fills landed within 1% of Fixed and
  # 63% off Tiered, which is strong evidence for Fixed, but that's an
  # inference, not a confirmation.
  @default_plan :fixed

  @fixed_per_share Decimal.new("0.005")
  @fixed_min_order Decimal.new("1.00")
  # ≤ 300k shares/month
  @tiered_per_share Decimal.new("0.0035")
  @tiered_min_order Decimal.new("0.35")
  # 1% of trade value, both plans
  @max_pct_of_value Decimal.new("0.01")

  # sale value, sells only
  @sec_rate Decimal.new("0.0000206")
  # shares sold, sells only
  @finra_taf Decimal.new("0.000195")
  # shares
  @finra_cat Decimal.new("0.000003")
  # tiered only
  @clearing_per_sh Decimal.new("0.00020")
  @clearing_max_pct Decimal.new("0.005")

  @doc """
  Commission for ONE order: `shares` at `value` (notional), `side` in
  `[:buy, :sell]`. Returns a `Decimal` dollar amount.

  The 1% cap applies to the commission (`base`) alone, before
  third-party fees — it caps what IBKR charges, not what the government
  does. The cap is also per order, same as the minimum: on a small,
  low-priced order it can be the binding term rather than the minimum.
  """
  @spec order_cost(Decimal.t(), Decimal.t(), :buy | :sell, :fixed | :tiered) :: Decimal.t()
  def order_cost(shares, value, side, plan \\ @default_plan) do
    uncapped_base =
      case plan do
        :fixed -> Decimal.max(@fixed_min_order, Decimal.mult(shares, @fixed_per_share))
        :tiered -> Decimal.max(@tiered_min_order, Decimal.mult(shares, @tiered_per_share))
      end

    base = Decimal.min(uncapped_base, Decimal.mult(value, @max_pct_of_value))

    clearing =
      case plan do
        :tiered ->
          Decimal.min(
            Decimal.mult(shares, @clearing_per_sh),
            Decimal.mult(value, @clearing_max_pct)
          )

        :fixed ->
          Decimal.new(0)
      end

    regulatory =
      case side do
        :sell ->
          value
          |> Decimal.mult(@sec_rate)
          |> Decimal.add(Decimal.mult(shares, @finra_taf))
          |> Decimal.add(Decimal.mult(shares, @finra_cat))

        :buy ->
          Decimal.mult(shares, @finra_cat)
      end

    base
    |> Decimal.add(clearing)
    |> Decimal.add(regulatory)
  end
end
