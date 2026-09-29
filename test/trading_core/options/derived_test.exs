defmodule TradingCore.Options.DerivedTest do
  use ExUnit.Case, async: true

  alias TradingCore.Options.Derived

  describe "values/5 (spread, theta %, lambda)" do
    # Live SPY 20261120 765C, 2026-09-24 after the close.
    test "computes decay and leverage from a live-shaped tick" do
      v = Derived.values(20.73, 766.52, 0.5737, -0.1988, nil)

      assert_in_delta v["run_theta_pct"], -0.959, 0.001
      assert_in_delta v["run_lambda"], 21.21, 0.01
      refute Map.has_key?(v, "run_spread")
    end

    test "spread in dollars and as a % of mid from a two-sided quote" do
      v = Derived.values(20.73, 766.52, 0.57, -0.2, %{bid: 20.70, ask: 20.76})

      assert_in_delta v["run_spread"], 0.06, 1.0e-9
      assert_in_delta v["run_spread_pct"], 0.2894, 0.0001
    end

    # IBKR sends bid/ask -1.0 when the book is closed: no market, which
    # must not read as a (negative or zero) spread.
    test "a closed-book quote yields no spread keys" do
      v = Derived.values(20.73, 766.52, 0.57, -0.2, %{bid: -1.0, ask: -1.0})

      refute Map.has_key?(v, "run_spread")
      refute Map.has_key?(v, "run_spread_pct")
    end

    test "missing inputs omit the key rather than zero it" do
      assert Derived.values(nil, 766.52, 0.57, -0.2, nil) == %{}
      assert Derived.values(0.0, 766.52, 0.57, -0.2, nil) == %{}

      v = Derived.values(20.73, nil, 0.57, nil, nil)
      assert v == %{}
    end
  end

  test "a per-year theta must be converted by the caller" do
    # Black-Scholes theta is per year; the caller passes theta / 365.
    per_year = -72.562
    v = Derived.values(20.73, 766.52, 0.5737, per_year / 365, nil)
    assert_in_delta v["run_theta_pct"], -0.959, 0.001
  end

  describe "run_premium_daily_vol" do
    test "IV / sqrt(252) * |lambda|: IV 13%, lambda 20 is about a 16% daily premium move" do
      vol = Derived.premium_daily_vol(0.13, 20)
      assert_in_delta vol, 0.13 / :math.sqrt(252) * 20, 1.0e-15
      assert_in_delta vol, 0.1638, 1.0e-4
    end

    test "a put (negative lambda) gives the same positive value" do
      assert Derived.premium_daily_vol(0.13, -20) == Derived.premium_daily_vol(0.13, 20)
    end

    test "matches trading_live's live SPY/QQQ readings" do
      assert_in_delta Derived.premium_daily_vol(0.140, -24.9), 0.220, 0.001
      assert_in_delta Derived.premium_daily_vol(0.204, -16.9), 0.218, 0.001
      assert_in_delta Derived.premium_daily_vol(0.141, 22.9), 0.203, 0.001
    end

    test "absent for missing, zero or negative IV and missing or zero lambda" do
      for {iv, lambda} <- [
            {nil, 20},
            {0, 20},
            {0.0, 20},
            {-0.1, 20},
            {0.13, nil},
            {0.13, 0},
            {0.13, 0.0}
          ] do
        assert Derived.premium_daily_vol(iv, lambda) == nil, "#{inspect({iv, lambda})}"
        assert Derived.premium_vol_values(iv, lambda) == %{}
      end
    end

    test "premium_vol_values/2 is the snapshot fragment" do
      assert %{"run_premium_daily_vol" => vol} = Derived.premium_vol_values(0.13, 20)
      assert vol == Derived.premium_daily_vol(0.13, 20)
    end

    test "values/6 adds it from the tick's own run_lambda; values/5 leaves it out" do
      # price 2.00, underlying 500, delta 0.5 -> lambda 125
      five = Derived.values(2.0, 500.0, 0.5, -0.1, nil)
      six = Derived.values(2.0, 500.0, 0.5, -0.1, nil, 0.14)

      refute Map.has_key?(five, "run_premium_daily_vol")
      assert Map.delete(six, "run_premium_daily_vol") == five
      assert six["run_premium_daily_vol"] == Derived.premium_daily_vol(0.14, six["run_lambda"])
    end

    test "values/6 omits it when lambda can't be computed" do
      refute Map.has_key?(
               Derived.values(nil, 500.0, 0.5, -0.1, nil, 0.14),
               "run_premium_daily_vol"
             )

      refute Map.has_key?(Derived.values(2.0, nil, 0.5, -0.1, nil, 0.14), "run_premium_daily_vol")
    end
  end
end
