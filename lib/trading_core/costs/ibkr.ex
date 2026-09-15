defmodule TradingCore.Costs.IBKR do
  @moduledoc """
  US equity and options commission per IBKR's published schedule.

  Charged PER ORDER, not per fill — an order filled in N executions pays
  one minimum. Callers must group fills by `broker_order_id` before
  calling `order_cost/4` or `option_cost/5`.

  Stock rates verified against
  interactivebrokers.com/en/pricing/commissions-stocks.php on 2026-09-08,
  and reconciled against real IBKR fills (see `TradingCore.Costs.IBKRTest`
  — every `describe` block there is named after a real trade). The SEC
  transaction fee rate resets annually (and mid-year when the SEC adjusts
  it) — re-read the page and update `@sec_rate` rather than assuming it is
  stable.

  `trading_core`'s existing `TradingCore.CostModel.commission/2` models
  IBKR Pro Fixed pricing per **fill** (not per order) and omits
  third-party fees entirely — reverse-engineered from
  `realized_pnl`/`realized_pnl_net` and confirmed to overcharge small
  test trades by 14-98% against real IBKR fills. This module is the
  corrected replacement; wiring callers over to it is each app's own
  follow-up, not done here.

  ## Options rates are UNVERIFIED — do not trust these numbers the way you
  ## trust the stock ones

  `option_cost/5`'s constants come from IBKR's published pricing page
  (interactivebrokers.com/en/pricing/commissions-options.php, read
  2026-09-15) — **not** reconciled against any real options fill, unlike
  every stock constant above. That reconciliation step is exactly what
  this module's own stock-side history warns against skipping (see
  `TradingCore.Costs.IBKRTest`'s reconciliation `describe` blocks): hand-
  deriving a rate from the pricing page, without checking it against a
  real trade confirmation's commission + regulatory-fee breakdown, is how
  the *original* per-fill/no-fees bug in `CostModel.commission/2` went
  undetected for as long as it did. Treat `option_cost/5`'s output as a
  reasonable estimate, not a verified number, until it's reconciled
  against real options fills the same way the stock formula was.

  Known gaps in `option_cost/5`, as of 2026-09-15:

    * **ORF (Options Regulatory Fee) is not modeled.** IBKR's page links
      to a separate per-exchange rate table for this that wasn't
      available when this was written. `option_cost/5`'s sell-side
      regulatory total is missing this component — a real sell order's
      actual cost will run slightly higher than what this function
      returns. Add `@orf_rate` and thread it into the `:sell` branch once
      that table is read.
    * **Only the Fixed plan is implemented.** IBKR Pro's options Tiered
      pricing is bracketed by *both* trailing monthly contract volume and
      the option's premium (e.g. at ≤10,000 contracts/month: \\$0.25/contract
      if premium < \\$0.05, \\$0.50 if \\$0.05–0.10, \\$0.65 if ≥ \\$0.10) — a
      materially different, more-parameterized shape than stock's flat
      per-share Tiered rate, needing its own premium/volume inputs rather
      than reusing this function's signature. `option_cost/5` raises on
      `:tiered` rather than silently using an incomplete or wrong rate.
    * **No percentage-of-notional cap.** Unlike stock's Fixed/Tiered
      commission (capped at 1% of trade value), IBKR's published options
      schedule shows no analogous cap — the pricing table gives only a
      flat per-contract rate and a flat \\$1.00 per-order minimum, no cap
      column. `option_cost/5` therefore has no cap logic at all; this is
      a structural difference from `order_cost/4`, not a missing
      constant.
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

  # --- Options -------------------------------------------------------
  #
  # UNVERIFIED against real fills — see this module's own moduledoc
  # section on options before trusting these numbers or this function's
  # output.

  @options_fixed_per_contract Decimal.new("0.65")
  @options_fixed_min_order Decimal.new("1.00")

  # all contracts, both plans, per IBKR's published page — not
  # Tiered-only the way stock's clearing fee is, and has no separate
  # percentage-of-notional cap.
  @occ_clearing_per_contract Decimal.new("0.025")

  # sale value, sells only — same rate as the stock @sec_rate, confirmed
  # on the same page read.
  @options_sec_rate Decimal.new("0.0000206")
  # contracts sold, sells only. Note this is FINRA's options Trading
  # Activity Fee, a different (larger, contract-denominated) rate than
  # stock's per-share @finra_taf — not the same constant reused.
  @options_finra_taf Decimal.new("0.00329")
  # contracts (both sides) — FINRA CAT, contract-denominated, not the
  # same constant as stock's per-share @finra_cat.
  @options_finra_cat Decimal.new("0.0003")

  @doc """
  Commission for ONE options order: `contracts` at `notional` (the
  contract's total notional — `strike (or premium) × 100 × contracts`,
  **not** `fill_price × contracts` the way stock's `value` is `fill_price
  × shares`), `side` in `[:buy, :sell]`. Only `plan: :fixed` is
  implemented — see this module's own moduledoc for why `:tiered` isn't,
  and why there is no percentage-of-notional cap here the way there is in
  `order_cost/4`. Returns a `Decimal` dollar amount.

  **UNVERIFIED against real fills — see this module's own moduledoc
  before trusting this function's output.** Also omits ORF (ORF is not
  yet modeled — see the moduledoc), so a real sell order's actual cost
  will run slightly higher than what this returns.
  """
  @spec option_cost(Decimal.t(), Decimal.t(), :buy | :sell, :fixed) :: Decimal.t()
  def option_cost(contracts, notional, side, plan \\ :fixed)

  def option_cost(contracts, notional, side, :fixed) do
    base =
      Decimal.max(@options_fixed_min_order, Decimal.mult(contracts, @options_fixed_per_contract))

    clearing = Decimal.mult(contracts, @occ_clearing_per_contract)

    regulatory =
      case side do
        :sell ->
          notional
          |> Decimal.mult(@options_sec_rate)
          |> Decimal.add(Decimal.mult(contracts, @options_finra_taf))
          |> Decimal.add(Decimal.mult(contracts, @options_finra_cat))

        :buy ->
          Decimal.mult(contracts, @options_finra_cat)
      end

    base
    |> Decimal.add(clearing)
    |> Decimal.add(regulatory)
  end

  def option_cost(_contracts, _notional, _side, :tiered) do
    raise ArgumentError,
          "option_cost/5 does not implement :tiered — IBKR Pro's options Tiered pricing " <>
            "is bracketed by both trailing monthly volume and the option's premium, a " <>
            "materially different shape than the Fixed per-contract rate this function " <>
            "implements. See this module's own moduledoc."
  end
end
