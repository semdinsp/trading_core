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
        target_dollar_volatility: Decimal.new("1000"),
        fractional_shares_enabled: true
      }

      assert {:ok, qty} = PositionSizing.calculate_qty(config, context)
      assert Decimal.equal?(qty, Decimal.new("500"))
    end

    test "accepts plain floats/integers for context values, not just Decimal" do
      config = %{"method" => "volatility_target"}

      context = %{
        daily_vol: 0.02,
        price: 100,
        target_dollar_volatility: 1000,
        fractional_shares_enabled: true
      }

      assert {:ok, qty} = PositionSizing.calculate_qty(config, context)
      assert Decimal.equal?(qty, Decimal.new("500"))
    end

    test "errors when daily_vol is missing from context" do
      config = %{"method" => "volatility_target"}

      context = %{
        price: Decimal.new("100"),
        target_dollar_volatility: Decimal.new("1000"),
        fractional_shares_enabled: true
      }

      assert {:error, :daily_vol_required} = PositionSizing.calculate_qty(config, context)
    end

    test "errors when price is missing from context" do
      config = %{"method" => "volatility_target"}

      context = %{
        daily_vol: Decimal.new("0.02"),
        target_dollar_volatility: Decimal.new("1000"),
        fractional_shares_enabled: true
      }

      assert {:error, :price_required} = PositionSizing.calculate_qty(config, context)
    end

    test "errors when target_dollar_volatility is missing from context" do
      config = %{"method" => "volatility_target"}

      context = %{
        daily_vol: Decimal.new("0.02"),
        price: Decimal.new("100"),
        fractional_shares_enabled: true
      }

      assert {:error, :target_dollar_volatility_required} =
               PositionSizing.calculate_qty(config, context)
    end

    test "errors when fractional_shares_enabled is missing from context" do
      config = %{"method" => "volatility_target"}

      context = %{
        daily_vol: Decimal.new("0.02"),
        price: Decimal.new("100"),
        target_dollar_volatility: Decimal.new("1000")
      }

      assert {:error, :fractional_shares_enabled_required} =
               PositionSizing.calculate_qty(config, context)
    end

    test "errors when daily_vol is zero" do
      config = %{"method" => "volatility_target"}

      context = %{
        daily_vol: Decimal.new("0"),
        price: Decimal.new("100"),
        target_dollar_volatility: Decimal.new("1000"),
        fractional_shares_enabled: true
      }

      assert {:error, :daily_volatility_unavailable} =
               PositionSizing.calculate_qty(config, context)
    end

    test "errors when price is zero" do
      config = %{"method" => "volatility_target"}

      context = %{
        daily_vol: Decimal.new("0.02"),
        price: Decimal.new("0"),
        target_dollar_volatility: Decimal.new("1000"),
        fractional_shares_enabled: true
      }

      assert {:error, :daily_volatility_unavailable} =
               PositionSizing.calculate_qty(config, context)
    end

    # Regression: IBKR's API rejects a fractional-quantity order outright
    # ("Fractional-sized order cannot be placed via API") -- confirmed
    # live after target_dollar_volatility was lowered, which made a
    # non-integer division result far more likely than at a larger
    # budget. fractional_shares_enabled: false must always yield a whole
    # share count.
    test "fractional_shares_enabled: false rounds UP to the nearest whole share" do
      config = %{"method" => "volatility_target"}

      context = %{
        daily_vol: Decimal.new("0.15"),
        price: Decimal.new("9.20"),
        target_dollar_volatility: Decimal.new("10"),
        fractional_shares_enabled: false
      }

      # raw = 10 / (0.15 * 9.20) = 7.246... -> rounds up to 8
      assert {:ok, qty} = PositionSizing.calculate_qty(config, context)
      assert Decimal.equal?(qty, Decimal.new("8"))
    end

    test "fractional_shares_enabled: false leaves an already-whole result unchanged" do
      config = %{"method" => "volatility_target"}

      context = %{
        daily_vol: Decimal.new("0.02"),
        price: Decimal.new("100"),
        target_dollar_volatility: Decimal.new("1000"),
        fractional_shares_enabled: false
      }

      assert {:ok, qty} = PositionSizing.calculate_qty(config, context)
      assert Decimal.equal?(qty, Decimal.new("500"))
    end

    test "fractional_shares_enabled: false never rounds down to 0" do
      config = %{"method" => "volatility_target"}

      context = %{
        daily_vol: Decimal.new("1"),
        price: Decimal.new("1000"),
        target_dollar_volatility: Decimal.new("1"),
        fractional_shares_enabled: false
      }

      # raw = 1 / (1 * 1000) = 0.001 -> rounds UP to 1, never down to 0
      assert {:ok, qty} = PositionSizing.calculate_qty(config, context)
      assert Decimal.equal?(qty, Decimal.new("1"))
    end

    test "fractional_shares_enabled: true returns the raw fractional result unchanged" do
      config = %{"method" => "volatility_target"}

      context = %{
        daily_vol: Decimal.new("0.15"),
        price: Decimal.new("9.20"),
        target_dollar_volatility: Decimal.new("10"),
        fractional_shares_enabled: true
      }

      assert {:ok, qty} = PositionSizing.calculate_qty(config, context)
      refute Decimal.integer?(qty)
    end
  end

  describe "resolve_volatility_target/4" do
    test "fetches symbol/price, calls daily_volatility_fn, and delegates to calculate_qty/2" do
      config = %{"method" => "volatility_target"}

      context = %{
        symbol: "AAPL",
        exchange: "NASDAQ",
        price: Decimal.new("100"),
        target_dollar_volatility: Decimal.new("1000"),
        fractional_shares_enabled: true
      }

      daily_volatility_fn = fn "AAPL", "NASDAQ" -> {:ok, Decimal.new("0.02")} end

      assert {:ok, qty} =
               PositionSizing.resolve_volatility_target(config, context, daily_volatility_fn)

      assert Decimal.equal?(qty, Decimal.new("500"))
    end

    test "passes exchange through as nil when absent from context" do
      config = %{"method" => "volatility_target"}

      context = %{
        symbol: "AAPL",
        price: Decimal.new("100"),
        target_dollar_volatility: Decimal.new("1000"),
        fractional_shares_enabled: true
      }

      daily_volatility_fn = fn "AAPL", nil -> {:ok, Decimal.new("0.02")} end

      assert {:ok, _qty} =
               PositionSizing.resolve_volatility_target(config, context, daily_volatility_fn)
    end

    test "errors when symbol is missing from context" do
      config = %{"method" => "volatility_target"}

      context = %{
        price: Decimal.new("100"),
        target_dollar_volatility: Decimal.new("1000"),
        fractional_shares_enabled: true
      }

      daily_volatility_fn = fn _symbol, _exchange -> {:ok, Decimal.new("0.02")} end

      assert {:error, :symbol_required} =
               PositionSizing.resolve_volatility_target(config, context, daily_volatility_fn)
    end

    test "errors with the default :price_required when price is missing" do
      config = %{"method" => "volatility_target"}

      context = %{
        symbol: "AAPL",
        target_dollar_volatility: Decimal.new("1000"),
        fractional_shares_enabled: true
      }

      daily_volatility_fn = fn _symbol, _exchange -> {:ok, Decimal.new("0.02")} end

      assert {:error, :price_required} =
               PositionSizing.resolve_volatility_target(config, context, daily_volatility_fn)
    end

    test "errors with a caller-supplied :price_error atom when price is missing" do
      config = %{"method" => "volatility_target"}

      context = %{
        symbol: "AAPL",
        target_dollar_volatility: Decimal.new("1000"),
        fractional_shares_enabled: true
      }

      daily_volatility_fn = fn _symbol, _exchange -> {:ok, Decimal.new("0.02")} end

      assert {:error, :price_unavailable} =
               PositionSizing.resolve_volatility_target(config, context, daily_volatility_fn,
                 price_error: :price_unavailable
               )
    end

    test "errors when fractional_shares_enabled is missing from context" do
      config = %{"method" => "volatility_target"}

      context = %{
        symbol: "AAPL",
        price: Decimal.new("100"),
        target_dollar_volatility: Decimal.new("1000")
      }

      daily_volatility_fn = fn _symbol, _exchange -> {:ok, Decimal.new("0.02")} end

      assert {:error, :fractional_shares_enabled_required} =
               PositionSizing.resolve_volatility_target(config, context, daily_volatility_fn)
    end

    test "normalizes any daily_volatility_fn error to :daily_volatility_unavailable" do
      config = %{"method" => "volatility_target"}

      context = %{
        symbol: "AAPL",
        price: Decimal.new("100"),
        target_dollar_volatility: Decimal.new("1000"),
        fractional_shares_enabled: true
      }

      daily_volatility_fn = fn _symbol, _exchange -> {:error, :not_connected} end

      assert {:error, :daily_volatility_unavailable} =
               PositionSizing.resolve_volatility_target(config, context, daily_volatility_fn)
    end
  end

  describe "resolve_volatility_target_with_estimate/4" do
    test "returns qty and the daily_vol used to compute it" do
      config = %{"method" => "volatility_target"}

      context = %{
        symbol: "AAPL",
        exchange: "NASDAQ",
        price: Decimal.new("100"),
        target_dollar_volatility: Decimal.new("1000"),
        fractional_shares_enabled: true
      }

      daily_volatility_fn = fn "AAPL", "NASDAQ" -> {:ok, Decimal.new("0.02")} end

      assert {:ok, qty, daily_vol} =
               PositionSizing.resolve_volatility_target_with_estimate(
                 config,
                 context,
                 daily_volatility_fn
               )

      assert Decimal.equal?(qty, Decimal.new("500"))
      assert Decimal.equal?(daily_vol, Decimal.new("0.02"))
    end

    test "errors the same way resolve_volatility_target/4 does" do
      config = %{"method" => "volatility_target"}

      context = %{
        price: Decimal.new("100"),
        target_dollar_volatility: Decimal.new("1000"),
        fractional_shares_enabled: true
      }

      daily_volatility_fn = fn _symbol, _exchange -> {:ok, Decimal.new("0.02")} end

      assert {:error, :symbol_required} =
               PositionSizing.resolve_volatility_target_with_estimate(
                 config,
                 context,
                 daily_volatility_fn
               )
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
