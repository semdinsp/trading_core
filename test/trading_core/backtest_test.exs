defmodule TradingCore.BacktestTest do
  use ExUnit.Case, async: true

  alias TradingCore.Backtest

  @base ~U[2026-01-01 09:30:00Z]

  defp bar(offset_minutes, open, high, low, close, volume \\ 1000) do
    %{
      ts: DateTime.add(@base, offset_minutes, :minute),
      open: d(open),
      high: d(high),
      low: d(low),
      close: d(close),
      volume: d(volume)
    }
  end

  defp d(value) when is_binary(value), do: Decimal.new(value)
  defp d(value) when is_integer(value), do: Decimal.new(value)
  defp d(value) when is_float(value), do: Decimal.from_float(value)

  describe "simple threshold entry, percent stop/target exit" do
    setup do
      # Entry: enter long when "close_price" (this symbol's own close, fed
      # via a :price signal spec) crosses above 100. No exit rule -- falls
      # back to risk_controls stop/target.
      strategy = %{
        "direction" => "long",
        "rules" => %{
          "entry" => %{"signal" => "close_price", "op" => "gt", "value" => 100},
          "exit" => nil
        },
        "params" => %{
          "risk_controls" => %{
            "method" => "percent_of_entry",
            "stop_loss_percent" => 2,
            "take_profit_percent" => 4
          }
        },
        "position_sizing" => %{"method" => "fixed_qty", "qty" => 10}
      }

      signal_specs = %{
        "close_price" => %{kind: :price}
      }

      {:ok, strategy: strategy, signal_specs: signal_specs}
    end

    test "enters at next bar's open after the crossing bar, and exits on target hit at next bar's open",
         %{strategy: strategy, signal_specs: signal_specs} do
      bars = [
        # bar 0: below threshold, no entry
        bar(0, 94, 96, 93, 95),
        # bar 1: close 105 > 100 -> entry signal fires; fills at bar 2's open (106)
        bar(1, 100, 106, 99, 105),
        # bar 2 (entry fill bar): open 106 = entry_price. stop = 103.88, target = 110.24
        bar(2, 106, 108, 105, 108),
        # bar 3: close 111 >= target 110.24 -> exit signal fires; fills at bar 4's open
        bar(3, 109, 112, 108, 111),
        # bar 4 (exit fill bar): open 112 = exit_price
        bar(4, 112, 113, 111, 112)
      ]

      bars_by_symbol = %{"AAPL" => bars}

      assert {:ok, [run]} = Backtest.run(strategy, bars_by_symbol, signal_specs: signal_specs)

      assert run.symbol == "AAPL"
      assert run.direction == "long"
      assert Decimal.equal?(run.entry_price, d("106"))
      assert run.entry_at == DateTime.add(@base, 2, :minute)
      assert Decimal.equal?(run.exit_price, d("112"))
      assert run.exit_at == DateTime.add(@base, 4, :minute)
      assert run.exit_reason == "target_hit"
      assert Decimal.equal?(run.qty, d("10"))

      # pnl = (exit - entry) * qty = (112 - 106) * 10 = 60
      assert Decimal.equal?(run.pnl, d("60"))
    end

    test "exits on stop-loss hit instead when price falls through the stop first", %{
      strategy: strategy,
      signal_specs: signal_specs
    } do
      bars = [
        bar(0, 94, 96, 93, 95),
        # entry signal fires on close 105 > 100
        bar(1, 100, 106, 99, 105),
        # entry fill bar: open 106 = entry_price, stop = 103.88
        bar(2, 106, 107, 105, 106),
        # close 103 <= stop 103.88 -> stopped out; fills at next bar's open
        bar(3, 104, 105, 102, 103),
        bar(4, 101, 102, 99, 100)
      ]

      bars_by_symbol = %{"AAPL" => bars}

      assert {:ok, [run]} = Backtest.run(strategy, bars_by_symbol, signal_specs: signal_specs)

      assert run.exit_reason == "stopped_out"
      assert Decimal.equal?(run.exit_price, d("101"))
      # pnl = (101 - 106) * 10 = -50
      assert Decimal.equal?(run.pnl, d("-50"))
    end

    test "a run still open at the end of the series is force-closed with exit_reason end_of_data",
         %{strategy: strategy, signal_specs: signal_specs} do
      bars = [
        bar(0, 94, 96, 93, 95),
        # entry fires, fills at bar 2's open
        bar(1, 100, 106, 99, 105),
        # entry fill bar -- price then stays flat, never hits stop/target
        bar(2, 106, 107, 105, 106),
        bar(3, 106, 107, 105, 106),
        bar(4, 106, 107, 105, 106)
      ]

      bars_by_symbol = %{"AAPL" => bars}

      assert {:ok, [run]} = Backtest.run(strategy, bars_by_symbol, signal_specs: signal_specs)

      assert run.exit_reason == "end_of_data"
      assert run.exit_at == DateTime.add(@base, 4, :minute)
      assert Decimal.equal?(run.exit_price, d("106"))
    end

    test "no entry at all when the threshold is never crossed", %{
      strategy: strategy,
      signal_specs: signal_specs
    } do
      bars = [bar(0, 90, 92, 89, 91), bar(1, 91, 93, 90, 92), bar(2, 92, 94, 91, 93)]
      bars_by_symbol = %{"AAPL" => bars}

      assert {:ok, []} = Backtest.run(strategy, bars_by_symbol, signal_specs: signal_specs)
    end
  end

  describe "short direction" do
    test "pnl sign is inverted for a short position" do
      strategy = %{
        "direction" => "short",
        "rules" => %{
          "entry" => %{"signal" => "close_price", "op" => "lt", "value" => 100},
          "exit" => nil
        },
        "params" => %{
          "risk_controls" => %{
            "method" => "percent_of_entry",
            "stop_loss_percent" => 2,
            "take_profit_percent" => 4
          }
        },
        "position_sizing" => %{"method" => "fixed_qty", "qty" => 5}
      }

      signal_specs = %{"close_price" => %{kind: :price}}

      bars = [
        bar(0, 105, 106, 104, 105),
        # close 95 < 100 -> entry fires; fills at bar 2's open (94)
        bar(1, 99, 100, 94, 95),
        # entry fill bar: open 94 = entry_price. short target = 94 * 0.96 = 90.24
        bar(2, 94, 95, 93, 92),
        # close 89 <= target 90.24 -> target hit; fills at bar 4's open (88)
        bar(3, 90, 91, 88, 89),
        bar(4, 88, 89, 87, 88)
      ]

      bars_by_symbol = %{"XYZ" => bars}

      assert {:ok, [run]} = Backtest.run(strategy, bars_by_symbol, signal_specs: signal_specs)

      assert run.direction == "short"
      assert Decimal.equal?(run.entry_price, d("94"))
      assert Decimal.equal?(run.exit_price, d("88"))
      assert run.exit_reason == "target_hit"
      # short pnl = (entry - exit) * qty = (94 - 88) * 5 = 30
      assert Decimal.equal?(run.pnl, d("30"))
    end
  end

  describe "multi-symbol scoping" do
    test "a :symbol-scoped signal computes independently per symbol" do
      strategy = %{
        "direction" => "long",
        "rules" => %{
          "entry" => %{"signal" => "close_price", "op" => "gt", "value" => 100},
          "exit" => nil
        },
        "params" => %{
          "risk_controls" => %{
            "method" => "percent_of_entry",
            "stop_loss_percent" => 2,
            "take_profit_percent" => 4
          }
        },
        "position_sizing" => %{"method" => "fixed_qty", "qty" => 1}
      }

      signal_specs = %{"close_price" => %{kind: :price}}

      # AAPL crosses the threshold at bar 1; MSFT never does.
      aapl_bars = [
        bar(0, 94, 96, 93, 95),
        bar(1, 100, 106, 99, 105),
        bar(2, 106, 108, 105, 108),
        bar(3, 108, 109, 107, 108)
      ]

      msft_bars = [
        bar(0, 50, 51, 49, 50),
        bar(1, 50, 51, 49, 50),
        bar(2, 50, 51, 49, 50),
        bar(3, 50, 51, 49, 50)
      ]

      bars_by_symbol = %{"AAPL" => aapl_bars, "MSFT" => msft_bars}

      assert {:ok, runs} = Backtest.run(strategy, bars_by_symbol, signal_specs: signal_specs)

      assert length(runs) == 1
      assert [run] = runs
      assert run.symbol == "AAPL"
    end

    test "a :global-scoped signal (e.g. one instrument's own price) is shared identically across every symbol in the pool" do
      # Entry rule references SPY's own price directly (a :global signal
      # sourced from SPY's own bars) rather than each traded symbol's own
      # price -- both AAPL and MSFT should enter/exit in lockstep, driven
      # by the shared SPY series, even though their own price bars differ.
      strategy = %{
        "direction" => "long",
        "rules" => %{
          "entry" => %{"signal" => "spy_price", "op" => "gt", "value" => 100},
          "exit" => %{"signal" => "spy_price", "op" => "lt", "value" => 100}
        },
        "params" => %{},
        "position_sizing" => %{"method" => "fixed_qty", "qty" => 1}
      }

      signal_specs = %{
        "spy_price" => %{kind: :price, scope: :global, symbol: "SPY"}
      }

      spy_bars = [
        bar(0, 95, 96, 94, 95),
        # spy close 105 > 100 -> both symbols' entry fires at bar 2's open
        bar(1, 100, 106, 99, 105),
        bar(2, 105, 106, 104, 105),
        # spy close 98 < 100 -> both symbols' exit fires at bar 4's open
        bar(3, 101, 102, 97, 98),
        bar(4, 97, 98, 96, 97)
      ]

      aapl_bars = [
        bar(0, 10, 11, 9, 10),
        bar(1, 10, 11, 9, 10),
        bar(2, 20, 21, 19, 20),
        bar(3, 21, 22, 20, 21),
        bar(4, 22, 23, 21, 22)
      ]

      msft_bars = [
        bar(0, 200, 201, 199, 200),
        bar(1, 200, 201, 199, 200),
        bar(2, 300, 301, 299, 300),
        bar(3, 301, 302, 300, 301),
        bar(4, 302, 303, 301, 302)
      ]

      bars_by_symbol = %{"AAPL" => aapl_bars, "MSFT" => msft_bars, "SPY" => spy_bars}

      assert {:ok, runs} = Backtest.run(strategy, bars_by_symbol, signal_specs: signal_specs)

      # AAPL, MSFT, and SPY each get exactly one run -- SPY is a real,
      # liquid, tradeable symbol like any other, so being the source of a
      # :global signal doesn't exempt it from also being walked/traded on
      # that same signal, same as every other symbol in bars_by_symbol.
      by_symbol = Enum.group_by(runs, & &1.symbol)
      assert Map.has_key?(by_symbol, "AAPL")
      assert Map.has_key?(by_symbol, "MSFT")
      assert Map.has_key?(by_symbol, "SPY")

      aapl_run = hd(by_symbol["AAPL"])
      msft_run = hd(by_symbol["MSFT"])

      # Both entered/exited at the same SPY-driven timestamps, using their
      # own respective price bars for entry/exit fill prices.
      assert aapl_run.entry_at == msft_run.entry_at
      assert aapl_run.exit_at == msft_run.exit_at
      assert Decimal.equal?(aapl_run.entry_price, d("20"))
      assert Decimal.equal?(msft_run.entry_price, d("300"))
    end
  end

  describe "kind: :volume" do
    test "a :symbol-scoped volume signal reads each bar's own volume field, not close" do
      strategy = %{
        "direction" => "long",
        "rules" => %{
          "entry" => %{"signal" => "bar_volume", "op" => "gt", "value" => 5000},
          "exit" => nil
        },
        "params" => %{},
        "position_sizing" => %{"method" => "fixed_qty", "qty" => 1}
      }

      signal_specs = %{"bar_volume" => %{kind: :volume}}

      bars = [
        bar(0, 100, 101, 99, 100, 1000),
        # volume 6000 > 5000 -> entry fires; fills at bar 2's open, despite
        # close price itself never crossing any threshold.
        bar(1, 100, 101, 99, 100, 6000),
        bar(2, 105, 106, 104, 105, 1000),
        bar(3, 105, 106, 104, 105, 1000),
        bar(4, 105, 106, 104, 105, 1000)
      ]

      bars_by_symbol = %{"AAPL" => bars}

      assert {:ok, [run]} = Backtest.run(strategy, bars_by_symbol, signal_specs: signal_specs)
      assert run.symbol == "AAPL"
      assert Decimal.equal?(run.entry_price, d("105"))
    end

    test "a :global-scoped volume signal (one instrument's own volume) is shared across the pool" do
      strategy = %{
        "direction" => "long",
        "rules" => %{
          "entry" => %{"signal" => "spy_volume", "op" => "gt", "value" => 5000},
          "exit" => nil
        },
        "params" => %{},
        "position_sizing" => %{"method" => "fixed_qty", "qty" => 1}
      }

      signal_specs = %{"spy_volume" => %{kind: :volume, scope: :global, symbol: "SPY"}}

      spy_bars = [
        bar(0, 100, 101, 99, 100, 1000),
        bar(1, 100, 101, 99, 100, 6000),
        bar(2, 100, 101, 99, 100, 1000),
        bar(3, 100, 101, 99, 100, 1000),
        bar(4, 100, 101, 99, 100, 1000)
      ]

      aapl_bars = [
        bar(0, 10, 11, 9, 10),
        bar(1, 10, 11, 9, 10),
        bar(2, 20, 21, 19, 20),
        bar(3, 21, 22, 20, 21),
        bar(4, 22, 23, 21, 22)
      ]

      bars_by_symbol = %{"AAPL" => aapl_bars, "SPY" => spy_bars}

      assert {:ok, runs} = Backtest.run(strategy, bars_by_symbol, signal_specs: signal_specs)

      by_symbol = Enum.group_by(runs, & &1.symbol)
      aapl_run = hd(by_symbol["AAPL"])

      # SPY's own bar-1 volume spike drives AAPL's entry, filled using
      # AAPL's own bar-2 open (20) -- same "shared :global signal, own
      # fill price" behavior the analogous :price test above verifies.
      assert Decimal.equal?(aapl_run.entry_price, d("20"))
    end
  end

  describe "kind: :vwap" do
    defp bar_with_vwap(offset_minutes, close, vwap) do
      offset_minutes
      |> bar(close, close, close, close)
      |> Map.put(:vwap, d(vwap))
    end

    test "a :symbol-scoped vwap signal reads each bar's own vwap field, not close" do
      strategy = %{
        "direction" => "long",
        "rules" => %{
          "entry" => %{"signal" => "bar_vwap", "op" => "gt", "value" => 102},
          "exit" => nil
        },
        "params" => %{},
        "position_sizing" => %{"method" => "fixed_qty", "qty" => 1}
      }

      signal_specs = %{"bar_vwap" => %{kind: :vwap}}

      bars = [
        bar_with_vwap(0, 100, 99),
        # vwap 103 > 102 -> entry fires despite close (100) never crossing
        # any threshold; fills at bar 2's open.
        bar_with_vwap(1, 100, 103),
        bar_with_vwap(2, 105, 104),
        bar_with_vwap(3, 105, 104),
        bar_with_vwap(4, 105, 104)
      ]

      bars_by_symbol = %{"AAPL" => bars}

      assert {:ok, [run]} = Backtest.run(strategy, bars_by_symbol, signal_specs: signal_specs)
      assert run.symbol == "AAPL"
      assert Decimal.equal?(run.entry_price, d("105"))
    end

    test "a bar with no :vwap key is treated as no value yet, not an error" do
      strategy = %{
        "direction" => "long",
        "rules" => %{
          "entry" => %{"signal" => "bar_vwap", "op" => "gt", "value" => 100},
          "exit" => nil
        },
        "params" => %{},
        "position_sizing" => %{"method" => "fixed_qty", "qty" => 1}
      }

      signal_specs = %{"bar_vwap" => %{kind: :vwap}}

      bars = [bar(0, 100, 101, 99, 100), bar(1, 100, 101, 99, 100)]
      bars_by_symbol = %{"AAPL" => bars}

      assert {:ok, []} = Backtest.run(strategy, bars_by_symbol, signal_specs: signal_specs)
    end

    test "a :global-scoped vwap signal (one instrument's own vwap) is shared across the pool" do
      strategy = %{
        "direction" => "long",
        "rules" => %{
          "entry" => %{"signal" => "spy_vwap", "op" => "gt", "value" => 102},
          "exit" => nil
        },
        "params" => %{},
        "position_sizing" => %{"method" => "fixed_qty", "qty" => 1}
      }

      signal_specs = %{"spy_vwap" => %{kind: :vwap, scope: :global, symbol: "SPY"}}

      spy_bars = [
        bar_with_vwap(0, 100, 99),
        bar_with_vwap(1, 100, 103),
        bar_with_vwap(2, 100, 104),
        bar_with_vwap(3, 100, 104),
        bar_with_vwap(4, 100, 104)
      ]

      aapl_bars = [
        bar(0, 10, 11, 9, 10),
        bar(1, 10, 11, 9, 10),
        bar(2, 20, 21, 19, 20),
        bar(3, 21, 22, 20, 21),
        bar(4, 22, 23, 21, 22)
      ]

      bars_by_symbol = %{"AAPL" => aapl_bars, "SPY" => spy_bars}

      assert {:ok, runs} = Backtest.run(strategy, bars_by_symbol, signal_specs: signal_specs)

      by_symbol = Enum.group_by(runs, & &1.symbol)
      aapl_run = hd(by_symbol["AAPL"])

      assert Decimal.equal?(aapl_run.entry_price, d("20"))
    end
  end

  describe "custom exit rule precedence" do
    test "a non-empty custom exit rule takes precedence over stop/target" do
      strategy = %{
        "direction" => "long",
        "rules" => %{
          "entry" => %{"signal" => "close_price", "op" => "gt", "value" => 100},
          "exit" => %{"signal" => "close_price", "op" => "gt", "value" => 107}
        },
        "params" => %{
          "risk_controls" => %{
            "method" => "percent_of_entry",
            # Very wide stop/target so only the custom rule can trigger the exit.
            "stop_loss_percent" => 50,
            "take_profit_percent" => 50
          }
        },
        "position_sizing" => %{"method" => "fixed_qty", "qty" => 1}
      }

      signal_specs = %{"close_price" => %{kind: :price}}

      bars = [
        bar(0, 94, 96, 93, 95),
        # entry fires, fills at bar 2's open (106)
        bar(1, 100, 106, 99, 105),
        bar(2, 106, 108, 105, 106),
        # close 108 > 107 -> custom exit rule fires (stop/target both far away)
        bar(3, 107, 109, 106, 108),
        bar(4, 109, 110, 108, 109)
      ]

      bars_by_symbol = %{"AAPL" => bars}

      assert {:ok, [run]} = Backtest.run(strategy, bars_by_symbol, signal_specs: signal_specs)

      assert run.exit_reason == "rule_exit"
      assert Decimal.equal?(run.exit_price, d("109"))
    end
  end

  describe "volatility_target sizing" do
    test "estimate_daily_vol/3 matches a hand-computed stdev of daily returns" do
      # Returns: (102-100)/100=0.02, (99-102)/102≈-0.029412, (105-99)/99≈0.060606
      bars = [bar(0, 100, 101, 99, 100), bar(1, 101, 103, 100, 102), bar(2, 100, 101, 97, 99), bar(3, 103, 106, 98, 105)]

      assert {:ok, daily_vol} = Backtest.estimate_daily_vol(bars, 3, 20)

      returns = [
        (102.0 - 100.0) / 100.0,
        (99.0 - 102.0) / 102.0,
        (105.0 - 99.0) / 99.0
      ]

      mean = Enum.sum(returns) / length(returns)
      variance = Enum.sum(Enum.map(returns, fn r -> (r - mean) * (r - mean) end)) / length(returns)
      expected = :math.sqrt(variance)

      assert_in_delta Decimal.to_float(daily_vol), expected, 0.0001
    end

    test "estimate_daily_vol/3 returns :insufficient_data with fewer than 2 bars" do
      bars = [bar(0, 100, 101, 99, 100)]
      assert :insufficient_data = Backtest.estimate_daily_vol(bars, 0, 20)
    end

    test "sizes a real entry using the estimated volatility" do
      strategy = %{
        "direction" => "long",
        "rules" => %{
          "entry" => %{"signal" => "close_price", "op" => "gt", "value" => 100},
          "exit" => nil
        },
        "params" => %{
          "risk_controls" => %{
            "method" => "percent_of_entry",
            "stop_loss_percent" => 50,
            "take_profit_percent" => 50
          }
        },
        "position_sizing" => %{"method" => "volatility_target"}
      }

      signal_specs = %{"close_price" => %{kind: :price}}

      bars = [
        bar(0, 98, 99, 97, 98),
        bar(1, 99, 100, 98, 99),
        bar(2, 99, 101, 98, 101),
        # entry fires here (close 105 > 100), fills at bar 4's open
        bar(3, 101, 106, 100, 105),
        bar(4, 106, 108, 105, 106),
        bar(5, 106, 107, 105, 106)
      ]

      bars_by_symbol = %{"AAPL" => bars}

      assert {:ok, [run]} =
               Backtest.run(strategy, bars_by_symbol,
                 signal_specs: signal_specs,
                 target_dollar_volatility: Decimal.new(1000)
               )

      # qty should be positive and finite -- exact value depends on the
      # trailing-window vol estimate, verified separately above; here we
      # just confirm sizing actually happened (didn't fall back/skip).
      assert Decimal.compare(run.qty, 0) == :gt
    end
  end

  describe "missing signal_specs" do
    test "returns an error naming the missing signal rather than crashing" do
      strategy = %{
        "direction" => "long",
        "rules" => %{
          "entry" => %{"signal" => "undeclared_signal", "op" => "gt", "value" => 100},
          "exit" => nil
        },
        "params" => %{},
        "position_sizing" => %{"method" => "fixed_qty", "qty" => 1}
      }

      bars_by_symbol = %{"AAPL" => [bar(0, 100, 101, 99, 100)]}

      assert {:error, {:missing_signal_specs, ["undeclared_signal"]}} =
               Backtest.run(strategy, bars_by_symbol, signal_specs: %{})
    end
  end

  describe "wrapping signal kind: derivative" do
    test "enters once a symbol-scoped derivative crosses above a threshold" do
      strategy = %{
        "direction" => "long",
        "rules" => %{
          "entry" => %{"signal" => "close_derivative", "op" => "gt", "value" => 0},
          "exit" => nil
        },
        "params" => %{
          "risk_controls" => %{
            "method" => "percent_of_entry",
            "stop_loss_percent" => 50,
            "take_profit_percent" => 50
          }
        },
        "position_sizing" => %{"method" => "fixed_qty", "qty" => 1}
      }

      signal_specs = %{
        "close_price" => %{kind: :price},
        "close_derivative" => %{kind: :derivative, parent: "close_price", window_ms: :timer.minutes(10)}
      }

      # Rising prices -> positive derivative once at least 2 samples exist.
      bars = [
        bar(0, 100, 101, 99, 100),
        # derivative computed from bar 0 -> bar 1 is positive (100 -> 105 over 1 min)
        bar(1, 100, 106, 99, 105),
        bar(2, 105, 107, 104, 106),
        bar(3, 106, 108, 105, 107)
      ]

      bars_by_symbol = %{"AAPL" => bars}

      assert {:ok, [run]} = Backtest.run(strategy, bars_by_symbol, signal_specs: signal_specs)

      assert run.entry_price != nil
    end
  end
end
