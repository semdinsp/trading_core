defmodule TradingCore.RegimeTest do
  use ExUnit.Case, async: true

  alias TradingCore.Regime

  describe "percentile_boundaries/3" do
    test "returns :insufficient_history below 20 values" do
      values = Enum.map(1..19, &(&1 * 1.0))

      assert Regime.percentile_boundaries(values, [0.333, 0.667]) ==
               {:error, :insufficient_history}
    end

    test "accepts exactly 20 values" do
      values = Enum.map(1..20, &(&1 * 1.0))

      assert {:ok, [_b1, _b2]} = Regime.percentile_boundaries(values, [0.333, 0.667])
    end

    test "hand-computed terciles over 1..21 (R-7 / PERCENTILE.INC method)" do
      # n = 21, rank = p * (n - 1) = p * 20.
      # p = 0.333 -> rank 6.66 -> interpolate between 7th (index 6, value 7)
      #   and 8th (index 7, value 8): 7 + 0.66 * (8 - 7) = 7.66
      # p = 0.667 -> rank 13.34 -> interpolate between 14th (index 13, value 14)
      #   and 15th (index 14, value 15): 14 + 0.34 * (15 - 14) = 14.34
      values = Enum.map(1..21, &(&1 * 1.0))

      assert {:ok, [b1, b2]} = Regime.percentile_boundaries(values, [0.333, 0.667])
      assert Decimal.equal?(b1, Decimal.new("7.66000000"))
      assert Decimal.equal?(b2, Decimal.new("14.34000000"))
    end

    test "order of input values doesn't matter" do
      ascending = Enum.map(1..25, &(&1 * 1.0))
      shuffled = Enum.shuffle(ascending)

      assert Regime.percentile_boundaries(ascending, [0.5]) ==
               Regime.percentile_boundaries(shuffled, [0.5])
    end

    test "ties collapse to the tied value" do
      values = List.duplicate(10.0, 20) ++ List.duplicate(20.0, 5)

      assert {:ok, [b]} = Regime.percentile_boundaries(values, [0.1])
      assert Decimal.equal?(b, Decimal.new("10.00000000"))
    end

    test "accepts mixed sample types (Decimal, float, integer, numeric string)" do
      values =
        [Decimal.new(10), 20.0, 30, "40"] ++ Enum.map(1..16, fn _ -> 25.0 end)

      assert {:ok, [_b]} = Regime.percentile_boundaries(values, [0.5])
    end

    test "boundaries are rounded to the default precision" do
      values = Enum.map(1..20, fn i -> i * 1.0 + 0.123_456_789_123 end)

      assert {:ok, [b]} = Regime.percentile_boundaries(values, [0.5])
      assert Decimal.equal?(b, Decimal.round(b, 8))
      assert b.coef |> Integer.digits() |> length() <= 10
    end
  end

  describe "classify_vol_absolute/2" do
    test "below the low band is :calm" do
      assert Regime.classify_vol_absolute(14.9, {15.0, 22.0}) == :calm
    end

    test "at the low band edge is :normal, not :calm" do
      assert Regime.classify_vol_absolute(15.0, {15.0, 22.0}) == :normal
    end

    test "between the bands is :normal" do
      assert Regime.classify_vol_absolute(18.0, {15.0, 22.0}) == :normal
    end

    test "at the high band edge is :stressed, not :normal" do
      assert Regime.classify_vol_absolute(22.0, {15.0, 22.0}) == :stressed
    end

    test "above the high band is :stressed" do
      assert Regime.classify_vol_absolute(30.0, {15.0, 22.0}) == :stressed
    end

    test "defaults to the {15.0, 22.0} bands" do
      assert Regime.classify_vol_absolute(12.0) == :calm
      assert Regime.classify_vol_absolute(18.0) == :normal
      assert Regime.classify_vol_absolute(25.0) == :stressed
    end

    test "accepts Decimal input" do
      assert Regime.classify_vol_absolute(Decimal.new("18.5"), {15.0, 22.0}) == :normal
    end
  end

  describe "classify_vol_percentile/2" do
    test "mirrors classify_vol_absolute/2's edge convention against supplied boundaries" do
      assert Regime.classify_vol_percentile(9.9, [10.0, 20.0]) == :calm
      assert Regime.classify_vol_percentile(10.0, [10.0, 20.0]) == :normal
      assert Regime.classify_vol_percentile(20.0, [10.0, 20.0]) == :stressed
    end
  end

  describe "classify_trend/4" do
    test "price above SMA with a positive slope is :up" do
      assert Regime.classify_trend(105.0, 100.0, 0.5) == :up
    end

    test "price below SMA with a negative slope is :down" do
      assert Regime.classify_trend(95.0, 100.0, -0.5) == :down
    end

    test "price above SMA but a flat/negative slope is :chop" do
      assert Regime.classify_trend(105.0, 100.0, 0.0) == :chop
      assert Regime.classify_trend(105.0, 100.0, -0.5) == :chop
    end

    test "price below SMA but a flat/positive slope is :chop" do
      assert Regime.classify_trend(95.0, 100.0, 0.0) == :chop
      assert Regime.classify_trend(95.0, 100.0, 0.5) == :chop
    end

    test "price exactly at SMA is :chop regardless of slope" do
      assert Regime.classify_trend(100.0, 100.0, 1.0) == :chop
      assert Regime.classify_trend(100.0, 100.0, -1.0) == :chop
    end

    test "slope_eps deadbands a barely-positive/negative slope to :chop" do
      assert Regime.classify_trend(105.0, 100.0, 0.05, slope_eps: 0.1) == :chop
      assert Regime.classify_trend(105.0, 100.0, 0.5, slope_eps: 0.1) == :up
    end
  end

  describe "ordinal/1" do
    test "vol states" do
      assert Regime.ordinal(:calm) == -1
      assert Regime.ordinal(:normal) == 0
      assert Regime.ordinal(:stressed) == 1
    end

    test "trend states" do
      assert Regime.ordinal(:down) == -1
      assert Regime.ordinal(:chop) == 0
      assert Regime.ordinal(:up) == 1
    end
  end

  describe "label/2 and parse_label/1 round-trip" do
    vol_states = [:calm, :normal, :stressed]
    trend_states = [:up, :chop, :down]

    for vol <- vol_states, trend <- trend_states do
      test "round-trips #{vol}|#{trend}" do
        label = Regime.label(unquote(vol), unquote(trend))
        assert label == "#{unquote(vol)}|#{unquote(trend)}"
        assert Regime.parse_label(label) == {:ok, {unquote(vol), unquote(trend)}}
      end
    end

    test "parse_label/1 rejects garbage" do
      assert Regime.parse_label("nonsense") == :error
      assert Regime.parse_label("calm") == :error
      assert Regime.parse_label("calm|up|extra") == :error
      assert Regime.parse_label("CALM|UP") == :error
      assert Regime.parse_label("") == :error
      assert Regime.parse_label(nil) == :error
    end
  end

  describe "stable_state/5" do
    test "returns new_state unchanged when it matches previous_state" do
      assert Regime.stable_state(:calm, :calm, 14.0, 15.0, 1.0) == :calm
    end

    test "does not flip when the crossing is within the margin" do
      # previous :normal, new classification says :calm (14.5 < 15.0),
      # but only 0.5 away from the 15.0 boundary with a margin of 1.0.
      assert Regime.stable_state(:calm, :normal, 14.5, 15.0, 1.0) == :normal
    end

    test "flips when the crossing exceeds the margin" do
      assert Regime.stable_state(:calm, :normal, 12.0, 15.0, 1.0) == :calm
    end

    test "exactly at the margin does not flip (requires strictly exceeding it)" do
      assert Regime.stable_state(:calm, :normal, 14.0, 15.0, 1.0) == :normal
    end

    test "works symmetrically on the other side of the boundary" do
      assert Regime.stable_state(:stressed, :normal, 22.5, 22.0, 1.0) == :normal
      assert Regime.stable_state(:stressed, :normal, 24.0, 22.0, 1.0) == :stressed
    end
  end
end
