defmodule TradingCore.StatsTest do
  use ExUnit.Case, async: true

  alias TradingCore.Stats

  describe "z/1" do
    test "z(:p90) < z(:p95) -- guards against the map values ever being swapped, which would silently invert every gate in both apps" do
      assert Stats.z(:p90) < Stats.z(:p95)
    end

    test "returns the known one-sided critical values" do
      assert Stats.z(:p90) == 1.2816
      assert Stats.z(:p95) == 1.645
    end
  end

  describe "lower_bound/4, upper_bound/4, bounds/4" do
    test "reproduces the live TRAIL-TICK-long lcb95/ucb95 value at :p95 (2026-09-07 universe metrics verification)" do
      mean = Decimal.new("0.36581")
      sd = Decimal.new("1.19838")
      n = 39

      lcb = Stats.lower_bound(mean, sd, n, :p95)
      ucb = Stats.upper_bound(mean, sd, n, :p95)

      assert Decimal.round(lcb, 5) == Decimal.new("0.05014")
      assert Decimal.round(ucb, 5) == Decimal.new("0.68148")
      assert Stats.bounds(mean, sd, n, :p95) == {lcb, ucb}
    end

    test "reproduces the live CG-03b normal|down lcb90 value at :p90 (regime tool verification)" do
      mean = Decimal.new("0.34912")
      sd = Decimal.new("1.24833")
      n = 31

      lcb = Stats.lower_bound(mean, sd, n, :p90)

      assert Decimal.round(lcb, 5) == Decimal.new("0.06178")
    end

    test "n < 2 returns nil, not 0.0 and not a crash" do
      assert Stats.lower_bound(Decimal.new("0.5"), Decimal.new("1.0"), 1, :p90) == nil
      assert Stats.upper_bound(Decimal.new("0.5"), Decimal.new("1.0"), 1, :p90) == nil
      assert Stats.bounds(Decimal.new("0.5"), Decimal.new("1.0"), 0, :p95) == {nil, nil}
    end

    test "nil n returns nil" do
      assert Stats.bounds(Decimal.new("0.5"), Decimal.new("1.0"), nil, :p90) == {nil, nil}
    end

    test "nil mean returns nil" do
      assert Stats.bounds(nil, Decimal.new("1.0"), 39, :p90) == {nil, nil}
    end

    test "nil sd returns nil" do
      assert Stats.bounds(Decimal.new("0.5"), nil, 39, :p90) == {nil, nil}
    end

    test "sd = 0 returns mean for both bounds -- degenerate but valid" do
      mean = Decimal.new("0.5")

      {lcb, ucb} = Stats.bounds(mean, Decimal.new("0"), 39, :p90)

      assert Decimal.equal?(lcb, mean)
      assert Decimal.equal?(ucb, mean)
    end

    test "symmetry: ucb - mean == mean - lcb, at either level" do
      mean = Decimal.new("0.5893")
      sd = Decimal.new("1.1822")
      n = 80

      for level <- [:p90, :p95] do
        {lcb, ucb} = Stats.bounds(mean, sd, n, level)

        upper_gap = Decimal.sub(ucb, mean)
        lower_gap = Decimal.sub(mean, lcb)

        assert Decimal.round(upper_gap, 10) == Decimal.round(lower_gap, 10)
      end
    end
  end

  describe "confidence_bounds/3 (deprecated) identity with bounds/4 at :p95" do
    test "identical for the TRAIL-TICK-long row" do
      mean = Decimal.new("0.36581")
      sd = Decimal.new("1.19838")
      n = 39

      assert Stats.confidence_bounds(mean, sd, n) == Stats.bounds(mean, sd, n, :p95)
    end

    test "identical for the H-short2 v15 normal|up row" do
      mean = Decimal.new("0.5893")
      sd = Decimal.new("1.1822")
      n = 80

      assert Stats.confidence_bounds(mean, sd, n) == Stats.bounds(mean, sd, n, :p95)
    end

    test "identical for the CG-03b normal|down row" do
      mean = Decimal.new("0.34912")
      sd = Decimal.new("1.24833")
      n = 31

      assert Stats.confidence_bounds(mean, sd, n) == Stats.bounds(mean, sd, n, :p95)
    end

    test "identical on the n < 2 and nil-argument edge cases" do
      assert Stats.confidence_bounds(Decimal.new("0.5"), Decimal.new("1.0"), 1) ==
               Stats.bounds(Decimal.new("0.5"), Decimal.new("1.0"), 1, :p95)

      assert Stats.confidence_bounds(nil, Decimal.new("1.0"), 39) ==
               Stats.bounds(nil, Decimal.new("1.0"), 39, :p95)
    end
  end

  describe "z_90_two_sided/0 (deprecated) identity with z(:p95)" do
    test "equal" do
      assert Stats.z_90_two_sided() == Stats.z(:p95)
    end
  end
end
