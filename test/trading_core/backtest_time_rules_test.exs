defmodule TradingCore.BacktestTimeRulesTest do
  use ExUnit.Case, async: true

  alias TradingCore.Backtest

  # Enters long whenever the close is above 100 and exits by rule when it
  # drops below 100; the stop/target are far away, so only the rule, the
  # time rules, the flatten or end_of_data close a run.
  @strategy %{
    "direction" => "long",
    "rules" => %{
      "entry" => %{"signal" => "close_price", "op" => "gt", "value" => 100},
      "exit" => %{"signal" => "close_price", "op" => "lt", "value" => 100}
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

  @specs %{"close_price" => %{kind: :price}}
  @opts [signal_specs: @specs]
  @flatten [signal_specs: @specs, flatten_at: ~T[15:55:00]]

  @thu ~D[2026-10-01]
  @fri ~D[2026-10-02]
  @sat ~D[2026-10-03]

  defp d(v) when is_integer(v), do: Decimal.new(v)
  defp d(v) when is_binary(v), do: Decimal.new(v)

  defp et(date, time),
    do: date |> DateTime.new!(time, "America/New_York") |> DateTime.shift_zone!("Etc/UTC")

  defp bar(date, time, close) do
    close = d(close)
    %{ts: et(date, time), open: close, high: close, low: close, close: close, volume: d(1000)}
  end

  # Minute bars from `from` to `to` (inclusive) ET on `date`, all at `price`.
  defp minutes(date, from, to, price) do
    from
    |> Stream.iterate(&Time.add(&1, 60))
    |> Enum.take_while(&(Time.compare(&1, to) != :gt))
    |> Enum.map(&bar(date, &1, price))
  end

  defp strategy(top_level \\ %{}, params \\ %{}) do
    @strategy
    |> Map.merge(top_level)
    |> Map.update!("params", &Map.merge(&1, params))
  end

  defp run(strategy, bars, opts \\ @opts), do: Backtest.run(strategy, %{"SPY" => bars}, opts)

  @window %{
    "usage_conditions" => %{
      "trading_hours" => %{"tz" => "America/New_York", "start" => "15:30", "end" => "15:45"}
    }
  }

  describe "usage_conditions.trading_hours" do
    test "the first fill is at the window's start" do
      bars = minutes(@thu, ~T[15:20:00], ~T[15:59:00], 101)

      assert {:ok, [run]} = run(strategy(%{}, @window), bars, @flatten)
      assert run.entry_at == et(@thu, ~T[15:30:00])
      assert run.exit_reason == "eod_flatten"
    end

    test "the end is inclusive: a fill at 15:45 is taken, one at 15:46 is not" do
      at_end =
        minutes(@thu, ~T[15:40:00], ~T[15:43:00], 99) ++
          minutes(@thu, ~T[15:44:00], ~T[15:50:00], 101)

      assert {:ok, [run]} = run(strategy(%{}, @window), at_end)
      assert run.entry_at == et(@thu, ~T[15:45:00])

      past_end =
        minutes(@thu, ~T[15:40:00], ~T[15:44:00], 99) ++
          minutes(@thu, ~T[15:45:00], ~T[15:50:00], 101)

      assert run(strategy(%{}, @window), past_end) == {:ok, []}
    end

    test "a window in another timezone is read in that timezone" do
      # 15:30-15:45 ET is 20:30-20:45 in Europe/Lisbon (WEST) on this date.
      lisbon = %{
        "usage_conditions" => %{
          "trading_hours" => %{"tz" => "Europe/Lisbon", "start" => "20:30", "end" => "20:45"}
        }
      }

      bars = minutes(@thu, ~T[15:20:00], ~T[15:50:00], 101)
      assert {:ok, [run]} = run(strategy(%{}, lisbon), bars)
      assert run.entry_at == et(@thu, ~T[15:30:00])
    end
  end

  describe "entry_delay_minutes" do
    test "no fill before open + N minutes" do
      bars = minutes(@thu, ~T[09:30:00], ~T[10:10:00], 101)

      assert {:ok, [run]} = run(strategy(%{"entry_delay_minutes" => 30}), bars)
      assert run.entry_at == et(@thu, ~T[10:00:00])
    end

    test "0 is off" do
      bars = minutes(@thu, ~T[09:30:00], ~T[09:40:00], 101)

      assert {:ok, [run]} = run(strategy(%{"entry_delay_minutes" => 0}), bars)
      assert run.entry_at == et(@thu, ~T[09:31:00])
    end

    test "blocks entries on a date with no session, as live fails closed" do
      bars = minutes(@sat, ~T[10:00:00], ~T[10:10:00], 101)

      assert {:ok, [_]} = run(strategy(), bars)
      assert run(strategy(%{"entry_delay_minutes" => 5}), bars) == {:ok, []}
    end
  end

  describe "reentry_cooldown_seconds" do
    # 101 from 10:00, one 99 bar at 10:05 that triggers the rule exit, then
    # 101 again.
    defp dip_bars do
      minutes(@thu, ~T[10:00:00], ~T[10:04:00], 101) ++
        [bar(@thu, ~T[10:05:00], 99)] ++ minutes(@thu, ~T[10:06:00], ~T[10:30:00], 101)
    end

    test "without a cooldown the next signal re-enters a bar after the exit" do
      assert {:ok, [first, second]} = run(strategy(), dip_bars())
      assert first.exit_reason == "rule_exit"
      assert DateTime.diff(second.entry_at, first.exit_at) == 60
    end

    test "no re-entry until N seconds after the previous exit" do
      assert {:ok, [first, second]} =
               run(strategy(%{}, %{"reentry_cooldown_seconds" => 600}), dip_bars())

      assert DateTime.diff(second.entry_at, first.exit_at) == 600
    end

    test "applies after a stop too, whatever the exit reason" do
      stop_strategy =
        strategy(%{}, %{
          "reentry_cooldown_seconds" => 900,
          "risk_controls" => %{
            "method" => "percent_of_entry",
            "stop_loss_percent" => 1,
            "take_profit_percent" => 50
          }
        })
        |> put_in(["rules", "exit"], nil)

      # Enters at 101, the 10:05 bar's close of 99.5 is below the 1% stop.
      bars =
        minutes(@thu, ~T[10:00:00], ~T[10:04:00], 101) ++
          [bar(@thu, ~T[10:05:00], "99.5")] ++ minutes(@thu, ~T[10:06:00], ~T[10:40:00], 101)

      assert {:ok, [first, second]} = run(stop_strategy, bars)
      assert first.exit_reason == "stopped_out"
      assert DateTime.diff(second.entry_at, first.exit_at) == 900
    end
  end

  describe "time_box_exit_et" do
    test "flattens at the close of the time box's bar and takes no new entry after it" do
      bars =
        minutes(@thu, ~T[13:50:00], ~T[13:59:00], 101) ++
          [bar(@thu, ~T[14:00:00], 103)] ++ minutes(@thu, ~T[14:01:00], ~T[14:30:00], 101)

      assert {:ok, [run]} = run(strategy(%{"time_box_exit_et" => "14:00"}), bars)
      assert run.exit_reason == "time_box_flatten"
      assert run.exit_at == et(@thu, ~T[14:00:00])
      assert Decimal.equal?(run.exit_price, 103)
    end

    test "accepts a Time, a string with seconds, or a params key" do
      bars = minutes(@thu, ~T[13:50:00], ~T[14:10:00], 101)

      for strategy <- [
            strategy(%{"time_box_exit_et" => ~T[14:00:00]}),
            strategy(%{"time_box_exit_et" => "14:00:00"}),
            strategy(%{}, %{"time_box_exit_et" => "14:00"})
          ] do
        assert {:ok, [run]} = run(strategy, bars)
        assert run.exit_at == et(@thu, ~T[14:00:00])
      end
    end

    test "wins over eod_flatten when both fall due on the same bar" do
      bars = minutes(@thu, ~T[15:40:00], ~T[15:59:00], 101)

      assert {:ok, [run]} = run(strategy(%{"time_box_exit_et" => "15:55"}), bars, @flatten)
      assert run.exit_reason == "time_box_flatten"
      assert run.exit_at == et(@thu, ~T[15:55:00])
    end

    test "an intrabar stop on the time box's bar still wins" do
      stop_strategy =
        strategy(%{"time_box_exit_et" => "14:00"}, %{
          "risk_controls" => %{
            "method" => "percent_of_entry",
            "stop_loss_percent" => 1,
            "take_profit_percent" => 50
          }
        })

      bars =
        minutes(@thu, ~T[13:55:00], ~T[13:59:00], 101) ++
          [%{bar(@thu, ~T[14:00:00], 101) | low: d(99)}] ++
          minutes(@thu, ~T[14:01:00], ~T[14:05:00], 101)

      assert {:ok, [run]} = run(stop_strategy, bars, @opts ++ [intrabar: true])
      assert run.exit_reason == "stopped_out"
    end
  end

  describe "close_after_hours" do
    test "any entry after the open is due at open + H" do
      bars = minutes(@thu, ~T[10:59:00], ~T[11:40:00], 101)

      assert {:ok, [run]} = run(strategy(%{"close_after_hours" => 2}), bars)
      assert run.entry_at == et(@thu, ~T[11:00:00])
      assert run.exit_reason == "close_after_hours"
      assert run.exit_at == et(@thu, ~T[11:30:00])
    end

    test "fractional hours, and no entry at or after open + H" do
      bars = minutes(@thu, ~T[09:30:00], ~T[10:30:00], 101)

      assert {:ok, [run]} = run(strategy(%{"close_after_hours" => 0.5}), bars)
      assert run.exit_at == et(@thu, ~T[10:00:00])
    end

    test "capped at the close on a half day" do
      half_day = ~D[2026-11-27]
      bars = minutes(half_day, ~T[12:50:00], ~T[13:05:00], 101)

      assert {:ok, [run]} = run(strategy(%{"close_after_hours" => 6}), bars)
      assert run.exit_reason == "close_after_hours"
      assert run.exit_at == et(half_day, ~T[13:00:00])
    end

    test "with no session, due H after entry" do
      # Ends on the bar after the exit, so its signal has no fill bar.
      bars = minutes(@sat, ~T[10:00:00], ~T[11:02:00], 101)

      assert {:ok, [run]} = run(strategy(%{"close_after_hours" => 1}), bars)
      assert run.exit_at == DateTime.add(run.entry_at, 3600)
    end
  end

  # A 1% stop, a far target and no exit rule; `params` merges over that.
  defp stop_strategy(params \\ %{}) do
    strategy(
      %{},
      Map.merge(
        %{
          "risk_controls" => %{
            "method" => "percent_of_entry",
            "stop_loss_percent" => 1,
            "take_profit_percent" => 50
          }
        },
        params
      )
    )
    |> put_in(["rules", "exit"], nil)
  end

  # Thursday: enters at 101, stopped out on the 10:05 close of 99.5, then
  # 101 again; Friday morning at 101.
  defp stop_out_bars do
    minutes(@thu, ~T[10:00:00], ~T[10:04:00], 101) ++
      [bar(@thu, ~T[10:05:00], "99.5")] ++
      minutes(@thu, ~T[10:06:00], ~T[10:20:00], 101) ++
      minutes(@fri, ~T[10:00:00], ~T[10:05:00], 101)
  end

  describe "max_stop_outs_per_day" do
    test "after N stop-outs, no entry on that symbol until the next ET date" do
      assert {:ok, [first, second]} =
               run(stop_strategy(%{"max_stop_outs_per_day" => 1}), stop_out_bars())

      assert first.exit_reason == "stopped_out"
      assert first.exit_category == "stop_loss"
      # Without :flatten_at, Thursday's last signal fills at Friday's
      # first bar; the cap is checked on the fill's date, Friday.
      assert second.entry_at == et(@fri, ~T[10:00:00])
    end

    test "below the cap re-entry is unchanged" do
      assert {:ok, [_first, second]} =
               run(stop_strategy(%{"max_stop_outs_per_day" => 2}), stop_out_bars())

      assert second.entry_at == et(@thu, ~T[10:07:00])

      assert run(stop_strategy(%{"max_stop_outs_per_day" => 2}), stop_out_bars()) ==
               run(stop_strategy(), stop_out_bars())
    end

    test "rule exits don't count" do
      assert {:ok, [first, second]} =
               run(strategy(%{}, %{"max_stop_outs_per_day" => 1}), dip_bars())

      assert first.exit_category == "signal_reversal"
      assert DateTime.diff(second.entry_at, first.exit_at) == 60
    end

    test "a ratchet stop-out is categorized ratchet and doesn't count" do
      ratchet =
        stop_strategy(%{
          "max_stop_outs_per_day" => 1,
          "exit_strategy" => %{"method" => "ratchet", "trigger_pct" => 1, "lock_pct" => "0.5"}
        })

      # Fills at 101; 103 reaches the 1% trigger and locks the stop at
      # 101.505; the 101 close then stops out above the entry stop.
      bars =
        minutes(@thu, ~T[10:00:00], ~T[10:02:00], 101) ++
          [bar(@thu, ~T[10:03:00], 103)] ++ minutes(@thu, ~T[10:04:00], ~T[10:10:00], 101)

      assert {:ok, [first, second | _]} = run(ratchet, bars)
      assert first.exit_reason == "stopped_out"
      assert first.exit_category == "ratchet"
      assert DateTime.diff(second.entry_at, first.exit_at) == 60
    end
  end

  describe "reentry_cooldown_exit_categories" do
    test "an exit outside the categories doesn't start the cooldown" do
      params = %{
        "reentry_cooldown_seconds" => 600,
        "reentry_cooldown_exit_categories" => ["stop_loss"]
      }

      assert {:ok, [first, second]} = run(strategy(%{}, params), dip_bars())
      assert first.exit_category == "signal_reversal"
      assert DateTime.diff(second.entry_at, first.exit_at) == 60
    end

    test "an exit in the categories does" do
      params = %{
        "reentry_cooldown_seconds" => 600,
        "reentry_cooldown_exit_categories" => ["stop_loss"]
      }

      assert {:ok, [first, second | _]} = run(stop_strategy(params), stop_out_bars())
      assert first.exit_category == "stop_loss"
      assert DateTime.diff(second.entry_at, first.exit_at) == 600
    end
  end

  describe "exit_category" do
    test "follows trading_system's ExitCategory for each exit reason" do
      assert {:ok, [run]} =
               run(
                 strategy(%{"time_box_exit_et" => "14:00"}),
                 minutes(@thu, ~T[13:50:00], ~T[14:05:00], 101)
               )

      assert run.exit_category == "time_box"

      assert {:ok, [run]} =
               run(
                 strategy(%{"close_after_hours" => 2}),
                 minutes(@thu, ~T[10:59:00], ~T[11:40:00], 101)
               )

      assert run.exit_category == "eod_flatten"

      assert {:ok, [run]} =
               run(strategy(), minutes(@thu, ~T[15:40:00], ~T[15:59:00], 101), @flatten)

      assert run.exit_category == "eod_flatten"

      assert {:ok, [run]} = run(strategy(), minutes(@thu, ~T[10:00:00], ~T[10:05:00], 101))
      assert run.exit_reason == "end_of_data"
      assert run.exit_category == nil
    end
  end

  describe "malformed rules" do
    test "are rejected with the key" do
      bars = minutes(@fri, ~T[10:00:00], ~T[10:05:00], 101)

      for {top_level, params, key} <- [
            {%{"time_box_exit_et" => "2pm"}, %{}, :time_box_exit_et},
            {%{"entry_delay_minutes" => -1}, %{}, :entry_delay_minutes},
            {%{"close_after_hours" => 0}, %{}, :close_after_hours},
            {%{}, %{"reentry_cooldown_seconds" => "60"}, :reentry_cooldown_seconds},
            {%{}, %{"reentry_cooldown_exit_categories" => []}, :reentry_cooldown_exit_categories},
            {%{}, %{"reentry_cooldown_exit_categories" => ["stopped_out"]},
             :reentry_cooldown_exit_categories},
            {%{}, %{"max_stop_outs_per_day" => "2"}, :max_stop_outs_per_day},
            {%{}, %{"usage_conditions" => %{"trading_hours" => %{"start" => "15:30"}}},
             :trading_hours},
            {%{},
             %{
               "usage_conditions" => %{
                 "trading_hours" => %{
                   "tz" => "Mars/Olympus",
                   "start" => "15:30",
                   "end" => "15:45"
                 }
               }
             }, :trading_hours}
          ] do
        assert run(strategy(top_level, params), bars) == {:error, {:invalid_time_rule, key}}
      end
    end

    test "absent or nil rules leave results unchanged" do
      bars = minutes(@fri, ~T[10:00:00], ~T[10:05:00], 101)

      nils =
        strategy(
          %{"time_box_exit_et" => nil, "entry_delay_minutes" => nil, "close_after_hours" => nil},
          %{"reentry_cooldown_seconds" => nil, "usage_conditions" => nil}
        )

      assert run(nils, bars) == run(strategy(), bars)
    end
  end
end
