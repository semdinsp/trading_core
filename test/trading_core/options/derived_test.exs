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
end
