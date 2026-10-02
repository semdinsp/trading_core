defmodule TradingCore.Options.GammaExposureTest do
  use ExUnit.Case, async: true

  alias TradingCore.Options.GammaExposure, as: GEX

  defp d(s), do: Decimal.new(s)

  # Spot 100, multiplier 100: each contract is
  # gamma × OI × 100 × 100² × 0.01 = gamma × OI × 10_000.
  #   call 0.05 × 1000 × 10_000 =  500_000
  #   call 0.02 ×  500 × 10_000 =  100_000
  #   put  0.04 × 2000 × 10_000 = -800_000
  @chain [
    %{right: :call, gamma: Decimal.new("0.05"), open_interest: 1000},
    %{right: :call, gamma: Decimal.new("0.02"), open_interest: 500},
    %{right: :put, gamma: Decimal.new("0.04"), open_interest: 2000}
  ]

  defp assert_dollars(actual, expected) do
    assert Decimal.equal?(actual, expected), "expected #{expected}, got #{actual}"
  end

  test "hand-computed chain" do
    assert {:ok, result} = GEX.net(@chain, 100)

    assert_dollars(result.calls, 600_000)
    assert_dollars(result.puts, -800_000)
    assert_dollars(result.net, -200_000)
    assert result.contracts_used == 3
  end

  test "calls count positive and puts negative" do
    assert {:ok, %{net: net}} = GEX.net([%{right: :call, gamma: 1, open_interest: 1}], 10)
    assert Decimal.compare(net, 0) == :gt

    assert {:ok, %{net: net}} = GEX.net([%{right: :put, gamma: 1, open_interest: 1}], 10)
    assert Decimal.compare(net, 0) == :lt
  end

  test "scales with spot squared" do
    {:ok, at_100} = GEX.net(@chain, 100)
    {:ok, at_200} = GEX.net(@chain, 200)

    assert_dollars(at_200.net, Decimal.mult(at_100.net, 4))
  end

  test "zero, negative, missing and malformed rows are skipped and not counted" do
    junk = [
      %{right: :call, gamma: 0, open_interest: 5000},
      %{right: :put, gamma: d("0.03"), open_interest: 0},
      %{right: :call, gamma: d("-0.01"), open_interest: 100},
      %{right: :put, gamma: nil, open_interest: 100},
      %{right: :call, gamma: d("0.01"), open_interest: "n/a"},
      %{right: "C", gamma: d("0.01"), open_interest: 100},
      %{gamma: d("0.01"), open_interest: 100},
      :not_a_contract
    ]

    assert {:ok, result} = GEX.net(junk ++ @chain, 100)
    assert_dollars(result.net, -200_000)
    assert result.contracts_used == 3

    assert {:ok, %{net: net, contracts_used: 0}} = GEX.net(junk, 100)
    assert_dollars(net, 0)
  end

  test "floats and strings are accepted at the edges" do
    chain = [
      %{right: :call, gamma: 0.05, open_interest: 1000.0},
      %{right: :call, gamma: "0.02", open_interest: "500"},
      %{right: :put, gamma: 0.04, open_interest: 2000}
    ]

    assert {:ok, result} = GEX.net(chain, 100.0)
    assert_dollars(result.net, -200_000)
  end

  test "the multiplier is an option" do
    assert {:ok, result} = GEX.net(@chain, 100, multiplier: 10)
    assert_dollars(result.net, -20_000)
  end

  test "results are rounded to whole dollars" do
    chain = [%{right: :call, gamma: d("0.0123456"), open_interest: 7}]
    assert {:ok, %{calls: calls, net: net}} = GEX.net(chain, d("763.99"))

    # 0.0123456 × 7 × 100 × 763.99² × 0.01 = 50441.22... -> 50441
    assert_dollars(calls, 50_441)
    assert calls.exp == 0
    assert net.exp == 0
  end

  test "invalid spot or multiplier is an error" do
    for spot <- [0, -1, nil, "abc", Decimal.new("NaN")] do
      assert GEX.net(@chain, spot) == {:error, :invalid_spot}
    end

    assert GEX.net(@chain, 100, multiplier: 0) == {:error, :invalid_multiplier}
    assert GEX.net(@chain, 100, multiplier: "x") == {:error, :invalid_multiplier}
  end
end
