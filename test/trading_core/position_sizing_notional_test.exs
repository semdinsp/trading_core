defmodule TradingCore.PositionSizingNotionalTest do
  use ExUnit.Case, async: true

  alias TradingCore.{Backtest, PositionSizing}

  defp d(v), do: Decimal.new(v)

  describe "fixed_notional" do
    @config %{"method" => "fixed_notional", "notional" => 10_000}

    test "notional / price, fractional by default" do
      assert {:ok, qty} = PositionSizing.calculate_qty(@config, %{price: d("400")})
      assert Decimal.equal?(qty, 25)

      assert {:ok, qty} = PositionSizing.calculate_qty(@config, %{price: d("300")})
      assert Decimal.equal?(qty, Decimal.div(10_000, 300))
    end

    test "rounds up to a whole share when fractional shares are off" do
      assert {:ok, qty} =
               PositionSizing.calculate_qty(@config, %{
                 price: d("300"),
                 fractional_shares_enabled: false
               })

      assert Decimal.equal?(qty, 34)
    end

    test "a missing or zero price is :price_required" do
      assert PositionSizing.calculate_qty(@config, %{}) == {:error, :price_required}
      assert PositionSizing.calculate_qty(@config, %{price: nil}) == {:error, :price_required}
      assert PositionSizing.calculate_qty(@config, %{price: d("0")}) == {:error, :price_required}
      assert PositionSizing.calculate_qty(@config, %{price: 0}) == {:error, :price_required}
    end

    test "a config without \"notional\" is :unknown_sizing_method" do
      assert PositionSizing.calculate_qty(%{"method" => "fixed_notional"}, %{price: d("10")}) ==
               {:error, :unknown_sizing_method}
    end
  end

  describe "percent_equity" do
    @config %{"method" => "percent_equity", "percent" => "0.1"}

    test "equity * percent / price" do
      assert {:ok, qty} =
               PositionSizing.calculate_qty(@config, %{equity: d("50000"), price: d("250")})

      assert Decimal.equal?(qty, 20)
    end

    test "needs equity and a positive price" do
      assert PositionSizing.calculate_qty(@config, %{price: d("250")}) ==
               {:error, :equity_required}

      assert PositionSizing.calculate_qty(@config, %{equity: d("50000"), price: d("0")}) ==
               {:error, :price_required}
    end
  end

  describe "risk_based" do
    @config %{"method" => "risk_based", "risk_percent" => "0.01"}

    test "equity * risk_percent / |entry - stop|" do
      context = %{equity: d("50000"), entry_price: d("100"), stop_loss_price: d("98")}
      assert {:ok, qty} = PositionSizing.calculate_qty(@config, context)
      # $500 at risk / $2 per share
      assert Decimal.equal?(qty, 250)
    end

    test "a missing stop, or one equal to the entry, is :stop_loss_price_required" do
      assert PositionSizing.calculate_qty(@config, %{equity: d("50000"), entry_price: d("100")}) ==
               {:error, :stop_loss_price_required}

      context = %{equity: d("50000"), entry_price: d("100"), stop_loss_price: d("100")}
      assert PositionSizing.calculate_qty(@config, context) == {:error, :stop_loss_price_required}
    end
  end

  describe "Backtest" do
    defp day(n), do: DateTime.new!(Date.add(~D[2026-09-01], n), ~T[20:00:00], "Etc/UTC")

    defp bar(n, open, close),
      do: %{
        ts: day(n),
        open: d(open),
        high: d(close),
        low: d(open),
        close: d(close),
        volume: d(1000)
      }

    defp strategy(sizing) do
      %{
        "direction" => "long",
        "rules" => %{
          "entry" => %{"signal" => "close_price", "op" => "gt", "value" => 0},
          "exit" => nil
        },
        "params" => %{
          "risk_controls" => %{
            "method" => "percent_of_entry",
            "stop_loss_percent" => 2,
            "take_profit_percent" => 50
          }
        },
        "position_sizing" => sizing
      }
    end

    @bars [{0, "100", "100"}, {1, "125", "126"}, {2, "126", "127"}]
    defp bars, do: Enum.map(@bars, fn {n, o, c} -> bar(n, o, c) end)
    @specs [signal_specs: %{"close_price" => %{kind: :price}}]

    test "fixed_notional runs have qty == notional / entry_price" do
      assert {:ok, [run]} =
               Backtest.run(
                 strategy(%{"method" => "fixed_notional", "notional" => 10_000}),
                 %{"SPY" => bars()},
                 @specs
               )

      # fills at day 1's open, 125
      assert Decimal.equal?(run.entry_price, 125)
      assert Decimal.equal?(run.qty, 80)
    end

    test "percent_equity and risk_based size from :sizing_equity" do
      opts = @specs ++ [sizing_equity: d("50000")]

      assert {:ok, [run]} =
               Backtest.run(
                 strategy(%{"method" => "percent_equity", "percent" => "0.1"}),
                 %{"SPY" => bars()},
                 opts
               )

      assert Decimal.equal?(run.qty, 40)

      assert {:ok, [run]} =
               Backtest.run(
                 strategy(%{"method" => "risk_based", "risk_percent" => "0.01"}),
                 %{"SPY" => bars()},
                 opts
               )

      # stop 2% under 125 = 122.5, so $500 / $2.50 per share
      assert Decimal.equal?(run.qty, 200)
    end

    test "equity-based sizing without :sizing_equity is an error, not a guess" do
      for sizing <- [
            %{"method" => "percent_equity", "percent" => "0.1"},
            %{"method" => "risk_based", "risk_percent" => "0.01"}
          ] do
        assert Backtest.run(strategy(sizing), %{"SPY" => bars()}, @specs) ==
                 {:error, :sizing_equity_required}

        assert Backtest.run(strategy(sizing), %{"SPY" => bars()}, @specs ++ [sizing_equity: 0]) ==
                 {:error, :sizing_equity_required}
      end

      # fixed_notional needs no equity
      assert {:ok, [_]} =
               Backtest.run(
                 strategy(%{"method" => "fixed_notional", "notional" => 10_000}),
                 %{"SPY" => bars()},
                 @specs
               )
    end
  end
end
