defmodule TradingCore.StatsTest do
  use ExUnit.Case, async: true

  alias TradingCore.Stats

  describe "z_90_two_sided/0" do
    test "is the two-sided 90% / one-sided 95% critical value" do
      assert Stats.z_90_two_sided() == 1.645
    end
  end

  describe "confidence_bounds/3" do
    test "reproduces the live TRAIL-TICK-long lcb90 value (2026-09-07 verification)" do
      mean = Decimal.new("0.36581")
      sd = Decimal.new("1.19838")
      n = 39

      {lcb, ucb} = Stats.confidence_bounds(mean, sd, n)

      assert Decimal.round(lcb, 5) == Decimal.new("0.05014")
      assert Decimal.round(ucb, 5) == Decimal.new("0.68148")
    end

    test "returns {nil, nil} for n = 1 (no crash, not {mean, mean})" do
      assert Stats.confidence_bounds(Decimal.new("0.5"), Decimal.new("1.0"), 1) == {nil, nil}
    end

    test "returns {nil, nil} for n = 0" do
      assert Stats.confidence_bounds(Decimal.new("0.5"), Decimal.new("1.0"), 0) == {nil, nil}
    end

    test "returns {nil, nil} when n is nil" do
      assert Stats.confidence_bounds(Decimal.new("0.5"), Decimal.new("1.0"), nil) == {nil, nil}
    end

    test "returns {nil, nil} when mean is nil" do
      assert Stats.confidence_bounds(nil, Decimal.new("1.0"), 39) == {nil, nil}
    end

    test "returns {nil, nil} when sd is nil" do
      assert Stats.confidence_bounds(Decimal.new("0.5"), nil, 39) == {nil, nil}
    end

    test "sd = 0 returns {mean, mean} -- degenerate but valid" do
      mean = Decimal.new("0.5")

      {lcb, ucb} = Stats.confidence_bounds(mean, Decimal.new("0"), 39)

      assert Decimal.equal?(lcb, mean)
      assert Decimal.equal?(ucb, mean)
    end

    test "symmetry: ucb - mean == mean - lcb" do
      mean = Decimal.new("0.5893")
      sd = Decimal.new("1.1822")
      n = 80

      {lcb, ucb} = Stats.confidence_bounds(mean, sd, n)

      upper_gap = Decimal.sub(ucb, mean)
      lower_gap = Decimal.sub(mean, lcb)

      assert Decimal.round(upper_gap, 10) == Decimal.round(lower_gap, 10)
    end

    test "symmetry holds for a smaller sample size too" do
      mean = Decimal.new("0.34912")
      sd = Decimal.new("1.24833")
      n = 31

      {lcb, ucb} = Stats.confidence_bounds(mean, sd, n)

      upper_gap = Decimal.sub(ucb, mean)
      lower_gap = Decimal.sub(mean, lcb)

      assert Decimal.round(upper_gap, 10) == Decimal.round(lower_gap, 10)
    end
  end
end
