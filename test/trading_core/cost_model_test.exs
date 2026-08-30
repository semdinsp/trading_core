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
