defmodule TradingCore.BacktestWarmupTest do
  use ExUnit.Case, async: true

  alias TradingCore.{Backtest, Volatility}

  defp d(v) when is_binary(v), do: Decimal.new(v)
  defp d(v) when is_integer(v), do: Decimal.new(v)
  defp d(v) when is_float(v), do: v |> Decimal.from_float() |> Decimal.round(2)

  # Daily bars at 16:00 ET (20:00 UTC in EDT), day 0 = 2026-07-01.
  @day0 ~D[2026-07-01]
  defp date(n), do: Date.add(@day0, n)

  defp bar(n, close, open \\ nil) do
    close = d(close)
    open = if open, do: d(open), else: close

    %{
      ts: DateTime.new!(date(n), ~T[20:00:00], "Etc/UTC"),
      open: open,
      high: Decimal.max(open, close),
      low: Decimal.min(open, close),
      close: close,
      volume: d(1000)
    }
  end

  # A gently wandering price (~1.5% daily moves) for warm-up history.
  defp wander(from, n, start) do
    :rand.seed(:exsss, {11, 12, 13})

    {bars, _} =
      Enum.map_reduce(from..(from + n - 1), start, fn i, p ->
        p = p * (1 + 0.015 * :rand.normal())
        {bar(i, p), p}
      end)

    bars
  end

  defp strategy(extra_params \\ %{}) do
    %{
      "direction" => "long",
      "rules" => %{
        "entry" => %{"signal" => "close_price", "op" => "gt", "value" => 0},
        "exit" => nil
      },
      "params" =>
        Map.merge(
          %{
            "risk_controls" => %{
              "method" => "percent_of_entry",
              "stop_loss_percent" => 50,
              "take_profit_percent" => 50
            }
          },
          extra_params
        ),
      "position_sizing" => %{"method" => "volatility_target"}
    }
  end

  defp opts(extra),
    do:
      [signal_specs: %{"close_price" => %{kind: :price}}, target_dollar_volatility: d(30)] ++
        extra

  # The reported case: NVDA 211.79, then a 211.76 open the next day.
  # A quiet start: 211.79 -> 211.76 -> 211.80, two near-flat returns.
  defp nvda_window,
    do: [bar(0, "211.79"), bar(1, "211.76"), bar(2, "211.80")] ++ wander(3, 10, 212.0)

  describe "the minimum-returns floor" do
    test "without it, one near-flat return sizes an enormous position (the bug)" do
      assert {:ok, [run | _]} =
               Backtest.run(
                 strategy(),
                 %{"NVDA" => nvda_window()},
                 opts(min_sizing_vol_returns: 1)
               )

      # Day 1's single return has a population stdev of exactly 0, which
      # sizing already refuses; day 2's two near-flat returns read a tiny
      # vol and size a huge position filled on day 3.
      assert run.entry_at == DateTime.new!(date(3), ~T[20:00:00], "Etc/UTC")
      assert Decimal.compare(run.qty, 500) == :gt
    end

    test "by default, entries wait for 5 daily returns" do
      assert {:ok, [run | _]} = Backtest.run(strategy(), %{"NVDA" => nvda_window()}, opts([]))

      # 5 returns first exist at day 5's close; it fills on day 6
      assert run.entry_at == DateTime.new!(date(6), ~T[20:00:00], "Etc/UTC")
      assert Decimal.compare(run.qty, 50) == :lt
    end
  end

  describe ":trade_from" do
    # 20 days of warm-up, then the window starts with the same near-flat pair.
    defp warmed do
      wander(0, 20, 211.0) ++
        [bar(20, "211.79"), bar(21, "211.76"), bar(22, "212.50", "211.80")] ++
        wander(23, 5, 212.0)
    end

    test "with warm-up history, day 1 of the window sizes off real volatility" do
      assert {:ok, [run | _]} =
               Backtest.run(strategy(), %{"NVDA" => warmed()}, opts(trade_from: date(20)))

      # the first signal is day 20's close; it fills day 21 with a normal size
      assert run.entry_at == DateTime.new!(date(21), ~T[20:00:00], "Etc/UTC")
      assert Decimal.compare(run.qty, 50) == :lt
    end

    test "no run starts before trade_from, and none carries in" do
      assert {:ok, runs} =
               Backtest.run(strategy(), %{"NVDA" => warmed()}, opts(trade_from: date(20)))

      assert runs != []

      for run <- runs do
        assert Date.compare(DateTime.to_date(run.entry_at), date(20)) != :lt
      end

      # Without it the same bars trade during the warm-up.
      assert {:ok, [first | _]} = Backtest.run(strategy(), %{"NVDA" => warmed()}, opts([]))
      assert Date.compare(DateTime.to_date(first.entry_at), date(20)) == :lt
    end

    test "an invalid trade_from is an error" do
      assert Backtest.run(strategy(), %{"NVDA" => warmed()}, opts(trade_from: "2026-07-21")) ==
               {:error, :invalid_trade_from}
    end
  end

  describe ":min_stop_vol_returns" do
    @vm %{
      "risk_controls" => %{
        "method" => "volatility_multiple",
        "sl_vol_mult" => 2,
        "tp_vol_mult" => 4
      }
    }

    test "below the floor the stop falls back to percent_of_entry; default leaves it on" do
      # The signal (close > 101) first fires on bar 3, with 3 returns behind it.
      bars = [bar(0, 100), bar(1, 101), bar(2, 100), bar(3, 102), bar(4, 102)]
      sizing = %{"position_sizing" => %{"method" => "fixed_qty", "qty" => 1}}

      strat =
        strategy(@vm)
        |> Map.merge(sizing)
        |> put_in(["rules", "entry"], %{"signal" => "close_price", "op" => "gt", "value" => 101})

      assert {:ok, [run | _]} = Backtest.run(strat, %{"X" => bars}, opts([]))
      assert run.stop_method == "volatility_multiple"

      assert {:ok, [run | _]} = Backtest.run(strat, %{"X" => bars}, opts(min_stop_vol_returns: 5))
      assert run.stop_method == "percent_of_entry"
    end
  end

  test "Volatility.ewma_daily_vol/2 honours :min_returns" do
    bars = [bar(0, 100), bar(1, 101), bar(2, 99)]
    assert {:ok, _} = Volatility.ewma_daily_vol(bars)
    assert {:ok, _} = Volatility.ewma_daily_vol(bars, min_returns: 2)
    assert Volatility.ewma_daily_vol(bars, min_returns: 3) == :insufficient_data
  end
end
