defmodule TradingCore.PositionSizingTest do
  use ExUnit.Case, async: true

  alias TradingCore.PositionSizing

  describe "fixed_qty" do
    test "returns the configured qty as a Decimal" do
      config = %{"method" => "fixed_qty", "qty" => 25}

      assert {:ok, qty} = PositionSizing.calculate_qty(config, %{})
      assert Decimal.equal?(qty, Decimal.new(25))
    end

    test "accepts a qty already given as a string" do
      config = %{"method" => "fixed_qty", "qty" => "10"}

      assert {:ok, qty} = PositionSizing.calculate_qty(config, %{})
      assert Decimal.equal?(qty, Decimal.new(10))
    end

    test "errors on an invalid qty value" do
      config = %{"method" => "fixed_qty", "qty" => "not-a-number"}

      assert {:error, :invalid_position_sizing_value} =
               PositionSizing.calculate_qty(config, %{})
    end
  end

  describe "volatility_target" do
    test "computes shares = target_dollar_volatility / (daily_vol * price)" do
      config = %{"method" => "volatility_target"}

      context = %{
        daily_vol: Decimal.new("0.02"),
        price: Decimal.new("100"),
        target_dollar_volatility: Decimal.new("1000")
      }

      assert {:ok, qty} = PositionSizing.calculate_qty(config, context)
      assert Decimal.equal?(qty, Decimal.new("500"))
    end

    test "accepts plain floats/integers for context values, not just Decimal" do
      config = %{"method" => "volatility_target"}

      context = %{daily_vol: 0.02, price: 100, target_dollar_volatility: 1000}

      assert {:ok, qty} = PositionSizing.calculate_qty(config, context)
      assert Decimal.equal?(qty, Decimal.new("500"))
    end

    test "errors when daily_vol is missing from context" do
      config = %{"method" => "volatility_target"}
      context = %{price: Decimal.new("100"), target_dollar_volatility: Decimal.new("1000")}

      assert {:error, :daily_vol_required} = PositionSizing.calculate_qty(config, context)
    end

    test "errors when price is missing from context" do
      config = %{"method" => "volatility_target"}
      context = %{daily_vol: Decimal.new("0.02"), target_dollar_volatility: Decimal.new("1000")}

      assert {:error, :price_required} = PositionSizing.calculate_qty(config, context)
    end

    test "errors when target_dollar_volatility is missing from context" do
      config = %{"method" => "volatility_target"}
      context = %{daily_vol: Decimal.new("0.02"), price: Decimal.new("100")}

      assert {:error, :target_dollar_volatility_required} =
               PositionSizing.calculate_qty(config, context)
    end

    test "errors when daily_vol is zero" do
      config = %{"method" => "volatility_target"}

      context = %{
        daily_vol: Decimal.new("0"),
        price: Decimal.new("100"),
        target_dollar_volatility: Decimal.new("1000")
      }

      assert {:error, :daily_volatility_unavailable} =
               PositionSizing.calculate_qty(config, context)
    end

    test "errors when price is zero" do
      config = %{"method" => "volatility_target"}

      context = %{
        daily_vol: Decimal.new("0.02"),
        price: Decimal.new("0"),
        target_dollar_volatility: Decimal.new("1000")
      }

      assert {:error, :daily_volatility_unavailable} =
               PositionSizing.calculate_qty(config, context)
    end
  end

  describe "unknown method" do
    test "errors on a missing method" do
      assert {:error, :unknown_sizing_method} = PositionSizing.calculate_qty(%{}, %{})
    end

    test "errors on an unrecognized method" do
      config = %{"method" => "percent_equity"}

      assert {:error, :unknown_sizing_method} = PositionSizing.calculate_qty(config, %{})
    end
  end
end
