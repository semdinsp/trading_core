defmodule TradingCore.Regime.ExposureTest do
  use ExUnit.Case, async: true

  alias TradingCore.Regime.Exposure

  defp d(s), do: Decimal.new(s)

  describe "sign/2" do
    cases = [
      {"long", "1.2", :long_market},
      {"long", "-3", :short_market},
      {"long", "0", :flat},
      {"short", "1.2", :short_market},
      {"short", "-3", :long_market},
      {"short", "0", :flat},
      {:long, "1", :long_market},
      {:short, "-1", :long_market}
    ]

    for {direction, beta, expected} <- cases do
      @direction direction
      @beta beta
      @expected expected
      test "#{inspect(direction)} × beta #{beta} ⇒ #{expected}" do
        assert Exposure.sign(@direction, Decimal.new(@beta)) == @expected
      end
    end

    test "short SQQQ (beta −3) is long the market" do
      assert Exposure.sign("short", -3) == :long_market
    end
  end

  describe "beta_dollars/3" do
    test "signs by direction × beta and rounds to cents" do
      assert Decimal.equal?(Exposure.beta_dollars("long", d("1.5"), d("1000")), d("1500.00"))
      assert Decimal.equal?(Exposure.beta_dollars("short", d("-3"), d("1000")), d("3000.00"))
      assert Decimal.equal?(Exposure.beta_dollars("short", d("1"), d("333.333")), d("-333.33"))
    end
  end

  describe "risk_per_unit/1" do
    test "uses stop distance × multiplier when stop and base are present" do
      assert {:ok, r, :stop} =
               Exposure.risk_per_unit(%{
                 stop_price: d("95"),
                 base_price: d("100"),
                 multiplier: 1,
                 daily_vol: d("0.02")
               })

      assert Decimal.equal?(r, 5)

      assert {:ok, r, :stop} =
               Exposure.risk_per_unit(%{stop_price: d("2.5"), base_price: d("2"), multiplier: 100})

      assert Decimal.equal?(r, 50)
    end

    test "falls back to daily_vol × base × multiplier" do
      assert {:ok, r, :daily_vol} =
               Exposure.risk_per_unit(%{
                 stop_price: nil,
                 base_price: d("100"),
                 multiplier: nil,
                 daily_vol: d("0.02")
               })

      assert Decimal.equal?(r, 2)
    end

    test "a zero stop distance falls through to daily_vol" do
      assert {:ok, _, :daily_vol} =
               Exposure.risk_per_unit(%{
                 stop_price: d("100"),
                 base_price: d("100"),
                 daily_vol: d("0.01")
               })
    end

    test "errors when neither branch is computable" do
      assert {:error, :missing_risk_input} = Exposure.risk_per_unit(%{base_price: d("100")})

      assert {:error, :missing_risk_input} =
               Exposure.risk_per_unit(%{stop_price: d("95"), daily_vol: d("0.02")})

      assert {:error, :missing_risk_input} = Exposure.risk_per_unit(%{})
    end
  end

  describe "bucket_totals/1" do
    test "empty book has a zero portfolio" do
      assert %{portfolio: %{count: 0} = p} = Exposure.bucket_totals([])
      assert Decimal.equal?(p.open_risk, 0)
    end

    test "sums per bucket and portfolio; gross is absolute, beta keeps sign" do
      positions = [
        %{bucket: "tick", open_risk: d("100.004"), notional: d("5000"), beta_dollars: d("15000")},
        %{bucket: "tick", open_risk: d("50"), notional: d("-2000"), beta_dollars: d("-2000")},
        %{bucket: "semis", open_risk: d("25"), notional: d("1000"), beta_dollars: d("1500")}
      ]

      totals = Exposure.bucket_totals(positions)

      assert totals["tick"].count == 2
      assert Decimal.equal?(totals["tick"].open_risk, d("150.00"))
      assert Decimal.equal?(totals["tick"].gross_notional, d("7000"))
      assert Decimal.equal?(totals["tick"].net_beta_dollars, d("13000"))
      assert totals.portfolio.count == 3
      assert Decimal.equal?(totals.portfolio.open_risk, d("175.00"))
      assert Decimal.equal?(totals.portfolio.gross_notional, d("8000"))
      assert Decimal.equal?(totals.portfolio.net_beta_dollars, d("14500"))
      assert totals["tick"].open_risk.exp == -2
    end
  end
end
