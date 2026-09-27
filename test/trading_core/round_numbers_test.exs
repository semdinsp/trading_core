defmodule TradingCore.RoundNumbersTest do
  use ExUnit.Case, async: true

  alias TradingCore.RoundNumbers

  # price 100, daily_vol 1%, buffer_vol_frac 0.1 -> buffer = 0.10; grid 0.50
  @opts [daily_vol: 0.01, price: 100]

  defp adj(level, kind, side, opts \\ []),
    do: RoundNumbers.adjust_detail(Decimal.new(level), kind, side, Keyword.merge(@opts, opts))

  defp eq?(%Decimal{} = a, b), do: Decimal.equal?(a, Decimal.new(b))

  describe "take-profit" do
    test "long: a target at or just above a round number is pulled one tick in front" do
      for level <- ["100.00", "100.05", "100.10"] do
        result = adj(level, :take_profit, "long")
        assert eq?(result.level, "99.99"), "#{level} -> #{result.level}"
        assert result.action == :pulled_in_front
        assert eq?(result.round_number, "100")
      end
    end

    test "long: a target outside the zone, or already in front, is left alone" do
      assert adj("100.20", :take_profit, "long").action == :none
      assert eq?(adj("99.95", :take_profit, "long").level, "99.95")
    end

    test "short: mirrored — a target at or just below a round number moves one tick above" do
      result = adj("99.95", :take_profit, "short")
      assert eq?(result.level, "100.01")
      assert result.action == :pulled_in_front
    end
  end

  describe "stop-loss" do
    test "long (stop-sell): in the zone just below a round number, :near moves in front of it" do
      result = adj("99.95", :stop_loss, "long", stop_zone: :near)
      assert eq?(result.level, "100.01")
      assert result.action == :moved_near
    end

    test "long: :far moves past the crowd zone" do
      result = adj("99.95", :stop_loss, "long", stop_zone: :far)
      # 100 - 0.10 - 0.01
      assert eq?(result.level, "99.89")
      assert result.action == :moved_far
    end

    test ":far is the default" do
      assert adj("99.95", :stop_loss, "long").action == :moved_far
    end

    test "long: a stop exactly on the round number is in the zone" do
      assert eq?(adj("100.00", :stop_loss, "long", stop_zone: :near).level, "100.01")
    end

    test "long: a stop outside the zone is left alone" do
      assert adj("99.80", :stop_loss, "long").action == :none
    end

    test "short (stop-buy): the zone is just above the round number" do
      assert eq?(adj("100.05", :stop_loss, "short", stop_zone: :near).level, "99.99")
      assert eq?(adj("100.05", :stop_loss, "short", stop_zone: :far).level, "100.11")
      assert adj("99.95", :stop_loss, "short").action == :none
    end

    test ":far snaps away from the round number so it stays out of the zone" do
      # buffer = 0.1 * 0.0123 * 100 = 0.123 -> 100 - 0.123 - 0.01 = 99.867 -> floor 99.86
      result = adj("99.95", :stop_loss, "long", daily_vol: 0.0123)
      assert eq?(result.level, "99.86")

      result = adj("100.05", :stop_loss, "short", daily_vol: 0.0123)
      assert eq?(result.level, "100.14")
    end
  end

  describe "entry guard" do
    test "an adjustment that would cross entry is skipped" do
      # :near would put a long stop at 100.01, above a 100.00 entry
      result = adj("99.95", :stop_loss, "long", stop_zone: :near, entry: 100)
      assert eq?(result.level, "99.95")
      assert result.action == :skipped_crosses_entry
    end

    test "an adjustment that stays on the right side of entry goes ahead" do
      assert adj("99.95", :stop_loss, "long", stop_zone: :near, entry: 102).action == :moved_near
    end
  end

  describe "no buffer" do
    test "without daily_vol or :buffer nothing moves; the level is only snapped" do
      result = RoundNumbers.adjust_detail(Decimal.new("100.004"), :take_profit, "long", [])
      assert eq?(result.level, "100.00")
      assert result.action == :none
      assert result.round_number == nil
    end

    test "a non-positive daily_vol counts as none" do
      assert adj("100.05", :take_profit, "long", daily_vol: 0).action == :none
    end

    test "an explicit :buffer replaces the vol-based one" do
      result =
        RoundNumbers.adjust_detail(Decimal.new("100.30"), :take_profit, "long", buffer: "0.5")

      assert eq?(result.level, "99.99")
    end
  end

  describe "grid" do
    test "equities: $0.50 at or above $10, $0.10 below" do
      assert eq?(RoundNumbers.grid_for(Decimal.new("10")), "0.50")
      assert eq?(RoundNumbers.grid_for(Decimal.new("9.99")), "0.10")
    end

    test "options: $0.05" do
      assert eq?(RoundNumbers.grid_for(Decimal.new("20"), instrument: :option), "0.05")

      result =
        RoundNumbers.adjust_detail(Decimal.new("2.07"), :take_profit, "long",
          instrument: :option,
          buffer: "0.03"
        )

      assert eq?(result.level, "2.04")
    end

    test "below $10 uses dimes" do
      result =
        RoundNumbers.adjust_detail(Decimal.new("5.02"), :take_profit, "long", buffer: "0.05")

      assert eq?(result.level, "4.99")
    end

    test "an explicit :grid and :tick_size are honoured" do
      result =
        RoundNumbers.adjust_detail(Decimal.new("100.3"), :take_profit, "long",
          grid: 1,
          tick_size: "0.05",
          buffer: "0.5"
        )

      assert eq?(result.level, "99.95")
    end
  end

  test "adjust/4 returns just the level, and accepts atom sides" do
    assert Decimal.equal?(
             RoundNumbers.adjust(Decimal.new("100.05"), :take_profit, :long, @opts),
             adj("100.05", :take_profit, "long").level
           )
  end
end
