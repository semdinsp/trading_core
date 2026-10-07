defmodule TradingCore.BacktestIntrabarRatchetTest do
  use ExUnit.Case, async: true

  alias TradingCore.Backtest

  # Daily bars; the entry signal fires on day 0 (close 100) and fills at
  # day 1's open, 100. Stop 1% (99 long / 101 short), take-profit 2%
  # (102 long / 98 short).
  defp d(v) when is_integer(v), do: Decimal.new(v)
  defp d(v) when is_binary(v), do: Decimal.new(v)

  defp day(n), do: DateTime.new!(Date.add(~D[2026-09-01], n), ~T[20:00:00], "Etc/UTC")

  defp bar(n, open, high, low, close),
    do: %{ts: day(n), open: d(open), high: d(high), low: d(low), close: d(close), volume: d(1000)}

  defp strategy(direction, exit_strategy) do
    entry =
      if direction == "long",
        do: %{"signal" => "close_price", "op" => "gte", "value" => 100},
        else: %{"signal" => "close_price", "op" => "lte", "value" => 100}

    %{
      "direction" => direction,
      "rules" => %{"entry" => entry, "exit" => nil},
      "params" => %{
        "risk_controls" => %{
          "method" => "percent_of_entry",
          "stop_loss_percent" => 1,
          "take_profit_percent" => 2
        },
        "exit_strategy" => exit_strategy
      },
      "position_sizing" => %{"method" => "fixed_qty", "qty" => 1}
    }
  end

  @ratchet_at_target %{"method" => "ratchet", "trigger_pct" => 2, "lock_pct" => 2}
  @ratchet_beyond_target %{"method" => "ratchet", "trigger_pct" => 3, "lock_pct" => 2}

  defp run(strategy, bars, opts \\ [intrabar: true]) do
    {:ok, runs} =
      Backtest.run(
        strategy,
        %{"SPY" => bars},
        [signal_specs: %{"close_price" => %{kind: :price}}] ++ opts
      )

    runs
  end

  # Signal day plus a fill day whose high reaches +2.5%.
  defp up_bars(rest) do
    [bar(0, 100, 100, 100, 100), bar(1, 100, "102.5", "99.5", "102.3")] ++ rest
  end

  describe "long, trigger at the take-profit (2% / 2%)" do
    test "the bar that reaches +2% ratchets instead of banking the target; the winner runs" do
      bars = up_bars([bar(2, "102.4", 104, "102.2", 104), bar(3, 104, 106, "103.5", 106)])

      assert [run] = run(strategy("long", @ratchet_at_target), bars)

      refute run.exit_reason == "target_hit"
      assert run.exit_reason == "end_of_data"
      assert Decimal.equal?(run.exit_price, 106)
      # entry levels are as set at entry, not the ratcheted ones
      assert Decimal.equal?(run.entry_stop_loss_price, 99)
      assert Decimal.equal?(run.entry_take_profit_price, 102)
    end

    test "after the ratchet the stop sits at entry +2% and a later bar stops out there" do
      bars = up_bars([bar(2, "102.4", 104, "101.5", "101.6")])

      assert [run] = run(strategy("long", @ratchet_at_target), bars)
      assert run.exit_reason == "stopped_out"
      assert run.exit_at == day(2)
      assert Decimal.equal?(run.exit_price, 102)
    end

    test "a bar touching the old stop and the trigger stops out at the old stop" do
      bars = [bar(0, 100, 100, 100, 100), bar(1, 100, "102.5", "98.9", 100)]

      assert [run] = run(strategy("long", @ratchet_at_target), bars)
      assert run.exit_reason == "stopped_out"
      assert Decimal.equal?(run.exit_price, 99)
    end

    test "the ratcheted stop is not assumed hit inside the ratchet bar itself" do
      # Reaches 102.5 (ratchet -> stop 102) and also trades down to 101.5,
      # but the order inside the bar is unknown: no intrabar stop at 102.
      # The close (101.8) is below the new stop, so the close check stops
      # it out at the next bar's open.
      bars = [
        bar(0, 100, 100, 100, 100),
        bar(1, 100, "102.5", "101.5", "101.8"),
        bar(2, "101.7", "101.9", "101.6", "101.7")
      ]

      assert [run] = run(strategy("long", @ratchet_at_target), bars)
      assert run.exit_reason == "stopped_out"
      assert run.exit_at == day(2)
      assert Decimal.equal?(run.exit_price, "101.7")
    end
  end

  describe "long, trigger beyond the take-profit (3% / TP 2%)" do
    test "the take-profit is reached first: target_hit" do
      assert [run] = run(strategy("long", @ratchet_beyond_target), up_bars([]))
      assert run.exit_reason == "target_hit"
      assert Decimal.equal?(run.exit_price, 102)
    end

    test "still target_hit when the same bar also reaches the trigger" do
      bars = [bar(0, 100, 100, 100, 100), bar(1, 100, "103.5", "99.5", 103)]

      assert [run] = run(strategy("long", @ratchet_beyond_target), bars)
      assert run.exit_reason == "target_hit"
      assert Decimal.equal?(run.exit_price, 102)
    end
  end

  describe "short mirror" do
    test "the bar that reaches -2% ratchets; the stop locks at 98 and a later bar stops out there" do
      bars = [
        bar(0, 100, 100, 100, 100),
        bar(1, 100, "100.5", "97.5", "97.7"),
        bar(2, "97.6", "98.5", 96, "98.4")
      ]

      assert [run] = run(strategy("short", @ratchet_at_target), bars)
      refute run.exit_reason == "target_hit"
      assert run.exit_reason == "stopped_out"
      assert Decimal.equal?(run.exit_price, 98)
    end

    test "trigger beyond the take-profit: target_hit" do
      bars = [bar(0, 100, 100, 100, 100), bar(1, 100, "100.5", "97.5", "97.7")]

      assert [run] = run(strategy("short", @ratchet_beyond_target), bars)
      assert run.exit_reason == "target_hit"
      assert Decimal.equal?(run.exit_price, 98)
    end

    test "a bar touching the old stop and the trigger stops out at the old stop" do
      bars = [bar(0, 100, 100, 100, 100), bar(1, 100, "101.1", "97.5", 100)]

      assert [run] = run(strategy("short", @ratchet_at_target), bars)
      assert run.exit_reason == "stopped_out"
      assert Decimal.equal?(run.exit_price, 101)
    end
  end

  test "close-based (intrabar: false) already ratchets on the close before the level check" do
    # The close (102.3) is beyond both the trigger and the take-profit:
    # the ratchet clears the target first, so no target_hit.
    bars = up_bars([bar(2, "102.4", 104, "102.2", 104), bar(3, 104, 106, "103.5", 106)])

    assert [run] = run(strategy("long", @ratchet_at_target), bars, intrabar: false)
    assert run.exit_reason == "end_of_data"
  end

  test "trailing: the trail follows the bar's high, not only its close" do
    trailing = %{"method" => "trailing", "trail_pct" => 3}

    strategy =
      put_in(strategy("long", trailing), ["params", "risk_controls", "take_profit_percent"], 50)

    # Day 1 trades up to 110 but closes at 105: the trail is 3% under 110
    # (106.7), not under 105. Day 2 dips to 106.6 and stops out at 106.7.
    bars = [
      bar(0, 100, 100, 100, 100),
      bar(1, 100, 110, "99.5", 107),
      bar(2, 107, 108, "106.6", 107)
    ]

    assert [run] = run(strategy, bars)
    assert run.exit_reason == "stopped_out"
    assert run.exit_at == day(2)
    assert Decimal.equal?(run.exit_price, "106.70")
  end

  test "no exit_strategy: intrabar behaviour is unchanged (target_hit at +2%)" do
    assert [run] = run(strategy("long", nil), up_bars([]))
    assert run.exit_reason == "target_hit"
    assert Decimal.equal?(run.exit_price, 102)
  end
end
