defmodule TradingCore.CostModelTest do
  use ExUnit.Case, async: true

  alias TradingCore.CostModel

  @threshold Decimal.new("25000")

  describe "simulate_fill_price/4" do
    test "a buy fills at last + half-spread when bid/ask are present" do
      price_data = %{bid: Decimal.new("99"), ask: Decimal.new("101"), last: Decimal.new("100")}

      fill_price =
        CostModel.simulate_fill_price(price_data, "buy", Decimal.new("10"),
          slippage_bps: 8,
          large_position_notional_threshold: @threshold
        )

      assert Decimal.equal?(fill_price, Decimal.new("101"))
    end

    test "a sell fills at last - half-spread when bid/ask are present" do
      price_data = %{bid: Decimal.new("99"), ask: Decimal.new("101"), last: Decimal.new("100")}

      fill_price =
        CostModel.simulate_fill_price(price_data, "sell", Decimal.new("10"),
          slippage_bps: 8,
          large_position_notional_threshold: @threshold
        )

      assert Decimal.equal?(fill_price, Decimal.new("99"))
    end

    test "a zero-width spread produces zero slippage" do
      price_data = %{bid: Decimal.new("50"), ask: Decimal.new("50"), last: Decimal.new("50")}

      fill_price =
        CostModel.simulate_fill_price(price_data, "buy", Decimal.new("10"),
          slippage_bps: 8,
          large_position_notional_threshold: @threshold
        )

      assert Decimal.equal?(fill_price, Decimal.new("50"))
    end

    test "falls back to flat slippage_bps against last when bid/ask are nil" do
      price_data = %{bid: nil, ask: nil, last: Decimal.new("100")}

      fill_price =
        CostModel.simulate_fill_price(price_data, "buy", Decimal.new("10"),
          slippage_bps: 8,
          large_position_notional_threshold: @threshold
        )

      # 100 * 8 / 10_000 = 0.08
      assert Decimal.equal?(fill_price, Decimal.new("100.08"))
    end

    test "flat bps fallback applies in the adverse direction for a sell" do
      price_data = %{bid: nil, ask: nil, last: Decimal.new("100")}

      fill_price =
        CostModel.simulate_fill_price(price_data, "sell", Decimal.new("10"),
          slippage_bps: 8,
          large_position_notional_threshold: @threshold
        )

      assert Decimal.equal?(fill_price, Decimal.new("99.92"))
    end

    test "coerces float bid/ask/last (a real market-data feed's shape) instead of raising" do
      # Confirmed live in trading_live: TradingHub.MarketData.Manager.
      # get_last_price/1 returns raw floats for IBKR ticks (not Decimal)
      # despite that function's own @type declaring Decimal.t() — this
      # used to crash every live-price entry attempt (Decimal.sub/2
      # raises ArgumentError on a bare float rather than converting it).
      # This is the one behavioral difference the extraction found
      # between the two pre-extraction copies (trading_live's had this
      # coercion, trading_system's did not) — see this module's own doc.
      price_data = %{bid: 99.0, ask: 101.0, last: 100.0}

      fill_price =
        CostModel.simulate_fill_price(price_data, "buy", Decimal.new("10"),
          slippage_bps: 8,
          large_position_notional_threshold: @threshold
        )

      assert Decimal.equal?(fill_price, Decimal.new("101"))
    end

    test "coerces a float last with nil bid/ask (flat-bps fallback path)" do
      price_data = %{bid: nil, ask: nil, last: 100.0}

      fill_price =
        CostModel.simulate_fill_price(price_data, "buy", Decimal.new("10"),
          slippage_bps: 8,
          large_position_notional_threshold: @threshold
        )

      assert Decimal.equal?(fill_price, Decimal.new("100.08"))
    end

    test "a crossed quote (bid > ask) never produces negative slippage" do
      price_data = %{bid: Decimal.new("101"), ask: Decimal.new("99"), last: Decimal.new("100")}

      fill_price =
        CostModel.simulate_fill_price(price_data, "buy", Decimal.new("10"),
          slippage_bps: 8,
          large_position_notional_threshold: @threshold
        )

      assert Decimal.equal?(fill_price, Decimal.new("100"))
    end

    test "notional over the threshold scales impact linearly, capped at 3x" do
      price_data = %{bid: Decimal.new("99"), ask: Decimal.new("101"), last: Decimal.new("100")}
      # notional = 100 * 500 = 50_000 = 2x the 25_000 threshold
      qty = Decimal.new("500")

      fill_price =
        CostModel.simulate_fill_price(price_data, "buy", qty,
          slippage_bps: 8,
          large_position_notional_threshold: @threshold
        )

      # half-spread 1 * impact multiplier 2 = 2 total slippage
      assert Decimal.equal?(fill_price, Decimal.new("102"))
    end

    test "impact multiplier is capped at 3x even far beyond the threshold" do
      price_data = %{bid: Decimal.new("99"), ask: Decimal.new("101"), last: Decimal.new("100")}
      # notional = 100 * 10_000 = 1_000_000, 40x the threshold
      qty = Decimal.new("10000")

      fill_price =
        CostModel.simulate_fill_price(price_data, "buy", qty,
          slippage_bps: 8,
          large_position_notional_threshold: @threshold
        )

      # half-spread 1 * capped multiplier 3 = 3 total slippage
      assert Decimal.equal?(fill_price, Decimal.new("103"))
    end

    test "notional at or below the threshold applies no extra impact" do
      price_data = %{bid: Decimal.new("99"), ask: Decimal.new("101"), last: Decimal.new("100")}
      # notional = 100 * 100 = 10_000, below the 25_000 threshold
      qty = Decimal.new("100")

      fill_price =
        CostModel.simulate_fill_price(price_data, "buy", qty,
          slippage_bps: 8,
          large_position_notional_threshold: @threshold
        )

      assert Decimal.equal?(fill_price, Decimal.new("101"))
    end

    test "a nil threshold disables impact scaling entirely" do
      price_data = %{bid: Decimal.new("99"), ask: Decimal.new("101"), last: Decimal.new("100")}
      qty = Decimal.new("10000")

      fill_price =
        CostModel.simulate_fill_price(price_data, "buy", qty,
          slippage_bps: 8,
          large_position_notional_threshold: nil
        )

      assert Decimal.equal?(fill_price, Decimal.new("101"))
    end
  end

  describe "simulate_fill_price/4 with :max_spread_bps (the bad-quote guard)" do
    # 10 bps flat fallback, no impact scaling; guard at 25 bps of last.
    @guard [
      slippage_bps: Decimal.new(10),
      large_position_notional_threshold: nil,
      max_spread_bps: 25
    ]
    @no_guard Keyword.delete(@guard, :max_spread_bps)
    @qty Decimal.new(100)

    defp quote(bid, ask, last) do
      %{bid: bid && Decimal.new(bid), ask: ask && Decimal.new(ask), last: Decimal.new(last)}
    end

    defp fill(price_data, side, opts),
      do: CostModel.simulate_fill_price(price_data, side, @qty, opts)

    test "a normal quote uses the half-spread" do
      # 100.00 / 100.10: 10 bps wide, last inside -> half-spread 0.05
      q = quote("100.00", "100.10", "100.05")
      assert Decimal.equal?(fill(q, "buy", @guard), Decimal.new("100.10"))
      assert Decimal.equal?(fill(q, "sell", @guard), Decimal.new("100.00"))
    end

    test "a stale quote (last outside bid/ask) uses the flat fallback" do
      # last 101 above the ask: 10 bps of 101 = 0.101
      q = quote("100.00", "100.10", "101")
      assert Decimal.equal?(fill(q, "buy", @guard), Decimal.new("101.101"))
      assert Decimal.equal?(fill(q, "sell", @guard), Decimal.new("100.899"))
    end

    test "a crossed quote (bid > ask) uses the flat fallback" do
      q = quote("100.10", "100.00", "100.05")
      # 10 bps of 100.05 = 0.10005
      assert Decimal.equal?(fill(q, "buy", @guard), Decimal.new("100.15005"))
    end

    test "a spread wider than max_spread_bps uses the flat fallback" do
      # the WFC incident shape: 79.01 / 80.69 around ~79.85 (~210 bps wide)
      q = quote("79.01", "80.69", "79.85")
      # 10 bps of 79.85 = 0.07985, not the 0.84 half-spread
      assert Decimal.equal?(fill(q, "buy", @guard), Decimal.new("79.92985"))
      # without the guard the half-spread applies, as before
      assert Decimal.equal?(fill(q, "buy", @no_guard), Decimal.new("80.69"))
    end

    test "a spread exactly at max_spread_bps is still used" do
      # 25 bps of 100.00 = 0.25
      q = quote("99.875", "100.125", "100.00")
      assert Decimal.equal?(fill(q, "buy", @guard), Decimal.new("100.125"))
    end

    test "nil bid/ask uses the flat fallback, guard or not" do
      q = quote(nil, nil, "100")
      assert Decimal.equal?(fill(q, "buy", @guard), Decimal.new("100.1"))
      assert fill(q, "buy", @guard) == fill(q, "buy", @no_guard)
    end

    test "without :max_spread_bps the result is exactly as before for every quote shape" do
      for q <- [
            quote("100.00", "100.10", "100.05"),
            quote("100.00", "100.10", "101"),
            quote("100.10", "100.00", "100.05"),
            quote("79.01", "80.69", "79.85"),
            quote(nil, nil, "100")
          ],
          side <- ["buy", "sell"] do
        assert fill(q, side, @no_guard) == fill(q, side, @no_guard ++ [max_spread_bps: nil])
      end
    end

    test "float quotes (a real feed's shape) go through the guard too" do
      q = %{bid: 79.01, ask: 80.69, last: 79.85}
      assert Decimal.equal?(fill(q, "buy", @guard), Decimal.new("79.92985"))
    end

    test "the guard composes with the impact multiplier" do
      # notional 100 * 100.05 = 10_005 over a 5_001 threshold -> ~2x impact
      opts = Keyword.put(@guard, :large_position_notional_threshold, Decimal.new(5_000))
      q = quote("79.01", "80.69", "79.85")
      # 10 bps fallback 0.07985 x (7985 / 5000 = 1.597)
      assert Decimal.equal?(
               fill(q, "buy", opts),
               Decimal.add(
                 Decimal.new("79.85"),
                 Decimal.mult(Decimal.new("0.07985"), Decimal.new("1.597"))
               )
             )
    end
  end

  describe "max_spread_bps_for/1" do
    test "25 bps for equities, nil (guard off) otherwise" do
      assert CostModel.max_spread_bps_for("equity") == 25
      assert CostModel.max_spread_bps_for("option") == nil
      assert CostModel.max_spread_bps_for(nil) == nil
    end
  end

  describe "order_commission/4" do
    test "a stock order is TradingCore.Costs.IBKR.order_cost/4 on the notional" do
      for {qty, price, side, atom} <- [
            {"100", "50.25", "buy", :buy},
            {"1", "10", "sell", :sell},
            {"5000", "3.10", "sell", :sell}
          ] do
        qty = Decimal.new(qty)
        price = Decimal.new(price)

        assert CostModel.order_commission(qty, price, side) ==
                 TradingCore.Costs.IBKR.order_cost(qty, Decimal.mult(qty, price), atom)
      end
    end

    test "an option order (multiplier 100) is option_cost/3 on contracts x premium x 100" do
      qty = Decimal.new(3)
      premium = Decimal.new("2.15")

      assert CostModel.order_commission(qty, premium, "sell", Decimal.new(100)) ==
               TradingCore.Costs.IBKR.option_cost(qty, Decimal.new("645.00"), :sell)
    end
  end

  describe "commission/2" do
    test "per-share cost applies once it exceeds the minimum" do
      # 1000 shares * $0.005 = $5.00, above the $1.00 minimum
      commission = CostModel.commission(Decimal.new("1000"), Decimal.new("100"))

      assert Decimal.equal?(commission, Decimal.new("5.00"))
    end

    test "the $1.00 minimum applies at small (e.g. 1-share) test sizes" do
      commission = CostModel.commission(Decimal.new("1"), Decimal.new("100"))

      assert Decimal.equal?(commission, Decimal.new("1.00"))
    end

    test "the minimum can exceed the entire trade's gross P&L at tiny sizes" do
      commission = CostModel.commission(Decimal.new("1"), Decimal.new("0.50"))

      assert Decimal.compare(commission, Decimal.new("1.00")) in [:lt, :eq]
    end

    test "commission is capped at 1% of trade value for a large qty at a low price" do
      # 100_000 shares * $0.005 = $500 base, but trade value is
      # 100_000 * $0.01 = $1000, so the 1% cap is $10 — far below $500.
      commission = CostModel.commission(Decimal.new("100000"), Decimal.new("0.01"))

      assert Decimal.equal?(commission, Decimal.new("10.00"))
    end

    test "commission is never below what the 1% cap allows when both are tiny" do
      # 1 share at $0.01: per-share cost $0.005, minimum $1.00, but trade
      # value is only $0.01 so the 1% cap ($0.0001) wins and is far below
      # the minimum.
      commission = CostModel.commission(Decimal.new("1"), Decimal.new("0.01"))

      assert Decimal.equal?(commission, Decimal.new("0.0001"))
    end
  end
end
