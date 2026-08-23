defmodule TradingCore.WelfordAccTest do
  use ExUnit.Case, async: true

  alias TradingCore.WelfordAcc

  test "new/0 starts with count 0, mean 0.0, m2 0.0" do
    acc = WelfordAcc.new()
    assert acc.count == 0
    assert acc.mean == 0.0
    assert acc.m2 == 0.0
  end

  test "variance/1 is 0.0 with fewer than 2 samples" do
    acc = WelfordAcc.new()
    assert WelfordAcc.variance(acc) == 0.0

    acc = WelfordAcc.add(acc, 5.0)
    assert WelfordAcc.variance(acc) == 0.0
  end

  test "mean/variance match the textbook formula for a small known sample set" do
    samples = [2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0]
    acc = Enum.reduce(samples, WelfordAcc.new(), &WelfordAcc.add(&2, &1))

    assert_in_delta acc.mean, 5.0, 0.0001
    # Sample variance (n - 1 denominator) of this set is 32/7 ≈ 4.5714.
    assert_in_delta WelfordAcc.variance(acc), 32 / 7, 0.0001
  end

  test "a flat (constant) sample set has zero variance" do
    acc = Enum.reduce([10.0, 10.0, 10.0], WelfordAcc.new(), &WelfordAcc.add(&2, &1))
    assert WelfordAcc.variance(acc) == 0.0
  end

  test "count increments with each add/2 call" do
    acc = WelfordAcc.new() |> WelfordAcc.add(1.0) |> WelfordAcc.add(2.0) |> WelfordAcc.add(3.0)
    assert acc.count == 3
  end
end
