defmodule TradingCore.Costs.IBKRTest do
  use ExUnit.Case, async: true

  alias TradingCore.Costs.IBKR

  describe "order_cost/4 reconciliation against real IBKR fills (Fixed plan)" do
    test "DC-long: ~10 shares @ $153, 5 round trips reconciles to ~$10.168 total" do
      shares = Decimal.new("10")
      value = Decimal.mult(shares, Decimal.new("153"))

      buy = IBKR.order_cost(shares, value, :buy, :fixed)
      sell = IBKR.order_cost(shares, value, :sell, :fixed)
      round_trip = Decimal.add(buy, sell)
      total = Decimal.mult(round_trip, 5)

      assert Decimal.round(total, 4) == Decimal.new("10.1676")
    end

    test "RegimeAB-2: ~21 shares @ $79, 1 round trip reconciles to ~$2.038" do
      shares = Decimal.new("21")
      value = Decimal.mult(shares, Decimal.new("79"))

      buy = IBKR.order_cost(shares, value, :buy, :fixed)
      sell = IBKR.order_cost(shares, value, :sell, :fixed)

      assert Decimal.round(Decimal.add(buy, sell), 4) == Decimal.new("2.0384")
    end

    test "F test: 1 share @ ~$17.50 -- the 1% cap binds at $0.175/order, not the $1.00 minimum" do
      shares = Decimal.new("1")
      value = Decimal.mult(shares, Decimal.new("17.50"))

      cost = IBKR.order_cost(shares, value, :buy, :fixed)

      assert Decimal.round(cost, 3) == Decimal.new("0.175")
    end
  end

  describe "order_cost/4 cap ordering" do
    test "the 1% cap applies to the commission base only, before third-party fees are added" do
      # A small, cheap order where value * 1% is below the $1.00 minimum,
      # so the cap -- not the minimum -- determines `base`. Regulatory
      # fees must still be added on top, uncapped.
      shares = Decimal.new("1")
      value = Decimal.new("10.00")

      cost = IBKR.order_cost(shares, value, :sell, :fixed)

      # base = min(max(1.00, 1*0.005), 10.00*0.01) = min(1.00, 0.10) = 0.10
      # regulatory (sell) = 10.00*0.0000206 + 1*0.000195 + 1*0.000003 = 0.000404
      assert Decimal.round(cost, 6) == Decimal.new("0.100404")
    end
  end

  describe "order_cost/4 plan differences" do
    test "tiered pricing includes clearing fees; fixed does not" do
      shares = Decimal.new("100")
      value = Decimal.mult(shares, Decimal.new("50"))

      fixed_cost = IBKR.order_cost(shares, value, :buy, :fixed)
      tiered_cost = IBKR.order_cost(shares, value, :buy, :tiered)

      # fixed: base = max(1.00, 100*0.005) = 1.00 (uncapped by 1% since 50 > 1.00);
      #   regulatory (buy) = 100*0.000003 = 0.0003 -> 1.0003
      assert Decimal.round(fixed_cost, 4) == Decimal.new("1.0003")

      # tiered: base = max(0.35, 100*0.0035) = 0.35;
      #   clearing = min(100*0.00020, 5000*0.005) = min(0.02, 25) = 0.02
      #   regulatory (buy) = 0.0003
      assert Decimal.round(tiered_cost, 4) == Decimal.new("0.3703")
      assert tiered_cost != fixed_cost
    end

    test "defaults to the fixed plan when no plan is given" do
      shares = Decimal.new("10")
      value = Decimal.mult(shares, Decimal.new("153"))

      assert IBKR.order_cost(shares, value, :buy) == IBKR.order_cost(shares, value, :buy, :fixed)
    end
  end

  describe "order_cost/4 buy vs sell regulatory fees" do
    test "buy orders only pay FINRA CAT, no SEC fee or FINRA TAF" do
      shares = Decimal.new("100")
      value = Decimal.mult(shares, Decimal.new("50"))

      cost = IBKR.order_cost(shares, value, :buy, :fixed)

      # base = max(1.00, 0.50) capped at 1% of 5000 = 50 -> 1.00
      # regulatory (buy) = 100 * 0.000003 = 0.0003
      assert Decimal.round(cost, 4) == Decimal.new("1.0003")
    end

    test "sell orders pay strictly more than an otherwise-identical buy order" do
      shares = Decimal.new("100")
      value = Decimal.mult(shares, Decimal.new("50"))

      buy_cost = IBKR.order_cost(shares, value, :buy, :fixed)
      sell_cost = IBKR.order_cost(shares, value, :sell, :fixed)

      assert Decimal.gt?(sell_cost, buy_cost)
    end
  end
end
