defmodule TradingCore.ExitStrategyTest do
  use ExUnit.Case, async: true

  alias TradingCore.ExitStrategy

  describe "no config" do
    test "nil config always returns :no_ratchet" do
      assert :no_ratchet =
               ExitStrategy.check(Decimal.new(100), Decimal.new(110), "long", nil, %{})
    end

    test "unrecognized method returns :no_ratchet" do
      config = %{"method" => "ladder"}

      assert :no_ratchet =
               ExitStrategy.check(Decimal.new(100), Decimal.new(110), "long", config, %{})
    end
  end

  describe "ratchet, long" do
    setup do
      # trigger at +5%, lock in +2% once triggered.
      {:ok, config: %{"method" => "ratchet", "trigger_pct" => 5, "lock_pct" => 2}}
    end

    test "does not fire below the trigger threshold", %{config: config} do
      entry = Decimal.new(100)
      # +4% < 5% trigger.
      current = Decimal.new(104)

      assert :no_ratchet = ExitStrategy.check(entry, current, "long", config, %{})
    end

    test "fires exactly at the trigger threshold and locks the hand-computed stop", %{
      config: config
    } do
      entry = Decimal.new(100)
      # +5% == 5% trigger -> fires. Locked stop = 100 * 1.02 = 102.
      current = Decimal.new(105)

      assert {:ratchet, new_stop, %{ratcheted_at: true}} =
               ExitStrategy.check(entry, current, "long", config, %{})

      assert Decimal.equal?(new_stop, Decimal.new("102.00"))
    end

    test "fires past the trigger threshold with the same locked stop regardless of overshoot", %{
      config: config
    } do
      entry = Decimal.new(100)
      # +20%, well past the 5% trigger -- lock_pct still governs the stop.
      current = Decimal.new(120)

      assert {:ratchet, new_stop, %{ratcheted_at: true}} =
               ExitStrategy.check(entry, current, "long", config, %{})

      assert Decimal.equal?(new_stop, Decimal.new("102.00"))
    end

    test "does not fire a second time once already ratcheted", %{config: config} do
      entry = Decimal.new(100)
      current = Decimal.new(130)
      state = %{ratcheted_at: true}

      assert :no_ratchet = ExitStrategy.check(entry, current, "long", config, state)
    end
  end

  describe "ratchet, short" do
    setup do
      {:ok, config: %{"method" => "ratchet", "trigger_pct" => 5, "lock_pct" => 2}}
    end

    test "fires when price falls to the trigger threshold and locks the hand-computed stop", %{
      config: config
    } do
      entry = Decimal.new(100)
      # -5% favorable move for a short -> fires. Locked stop = 100 * 0.98 = 98.
      current = Decimal.new(95)

      assert {:ratchet, new_stop, %{ratcheted_at: true}} =
               ExitStrategy.check(entry, current, "short", config, %{})

      assert Decimal.equal?(new_stop, Decimal.new("98.00"))
    end

    test "does not fire when price is unfavorable", %{config: config} do
      entry = Decimal.new(100)
      current = Decimal.new(110)

      assert :no_ratchet = ExitStrategy.check(entry, current, "short", config, %{})
    end
  end

  describe "trailing, long" do
    setup do
      {:ok, config: %{"method" => "trailing", "trail_pct" => 3}}
    end

    test "first favorable tick sets the high-water-mark and trails 3% behind it", %{
      config: config
    } do
      entry = Decimal.new(100)
      # No prior high-water-mark -> defaults to entry_price (100). 110 > 100
      # is a new high -> trail. Stop = 110 * 0.97 = 106.7.
      current = Decimal.new(110)

      assert {:trail, new_stop, %{trailing_high_water_mark: hwm}} =
               ExitStrategy.check(entry, current, "long", config, %{})

      assert Decimal.equal?(hwm, Decimal.new(110))
      assert Decimal.equal?(new_stop, Decimal.new("106.700"))
    end

    test "a pullback that doesn't beat the high-water-mark does not move the stop", %{
      config: config
    } do
      entry = Decimal.new(100)
      state = %{trailing_high_water_mark: Decimal.new(110)}
      # 105 < 110 existing high-water-mark -> no new extreme.
      current = Decimal.new(105)

      assert :no_ratchet = ExitStrategy.check(entry, current, "long", config, state)
    end

    test "a new higher high advances the high-water-mark and tightens the stop further", %{
      config: config
    } do
      entry = Decimal.new(100)
      state = %{trailing_high_water_mark: Decimal.new(110)}
      # New high of 120 -> stop = 120 * 0.97 = 116.4, tighter than the
      # previous 106.7.
      current = Decimal.new(120)

      assert {:trail, new_stop, %{trailing_high_water_mark: hwm}} =
               ExitStrategy.check(entry, current, "long", config, state)

      assert Decimal.equal?(hwm, Decimal.new(120))
      assert Decimal.equal?(new_stop, Decimal.new("116.400"))
    end

    test "hand-computed sequence: 100 -> 110 -> 105 -> 130 trails correctly at each step", %{
      config: config
    } do
      entry = Decimal.new(100)

      # Tick 1: 110 is a new high -> trail to 106.7.
      assert {:trail, stop1, updates1} =
               ExitStrategy.check(entry, Decimal.new(110), "long", config, %{})

      assert Decimal.equal?(stop1, Decimal.new("106.700"))
      state = updates1

      # Tick 2: 105 < 110 -> no move.
      assert :no_ratchet = ExitStrategy.check(entry, Decimal.new(105), "long", config, state)

      # Tick 3: 130 is a new high -> trail to 130 * 0.97 = 126.1.
      assert {:trail, stop3, %{trailing_high_water_mark: hwm3}} =
               ExitStrategy.check(entry, Decimal.new(130), "long", config, state)

      assert Decimal.equal?(hwm3, Decimal.new(130))
      assert Decimal.equal?(stop3, Decimal.new("126.100"))
    end
  end

  describe "trailing, short" do
    setup do
      {:ok, config: %{"method" => "trailing", "trail_pct" => 3}}
    end

    test "a falling price sets a new (lower) high-water-mark and trails above it", %{
      config: config
    } do
      entry = Decimal.new(100)
      # No prior high-water-mark -> defaults to entry_price (100). 90 < 100
      # is more favorable for a short -> trail. Stop = 90 * 1.03 = 92.7.
      current = Decimal.new(90)

      assert {:trail, new_stop, %{trailing_high_water_mark: hwm}} =
               ExitStrategy.check(entry, current, "short", config, %{})

      assert Decimal.equal?(hwm, Decimal.new(90))
      assert Decimal.equal?(new_stop, Decimal.new("92.700"))
    end

    test "a bounce that doesn't beat the low does not move the stop", %{config: config} do
      entry = Decimal.new(100)
      state = %{trailing_high_water_mark: Decimal.new(90)}
      current = Decimal.new(95)

      assert :no_ratchet = ExitStrategy.check(entry, current, "short", config, state)
    end
  end

  describe "missing required config keys" do
    test "ratchet without trigger_pct never fires" do
      config = %{"method" => "ratchet", "lock_pct" => 2}

      assert :no_ratchet =
               ExitStrategy.check(Decimal.new(100), Decimal.new(200), "long", config, %{})
    end

    test "trailing without trail_pct never fires" do
      config = %{"method" => "trailing"}

      assert :no_ratchet =
               ExitStrategy.check(Decimal.new(100), Decimal.new(200), "long", config, %{})
    end
  end
end
