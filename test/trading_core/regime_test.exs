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

  describe "sma_and_slope/3" do
    defp decimals(range), do: Enum.map(range, &Decimal.new/1)

    test "{nil, nil} with fewer than window prior closes" do
      assert Regime.sma_and_slope(decimals(101..119), Decimal.new(120), 20) == {nil, nil}
      assert Regime.sma_and_slope([], Decimal.new(120), 20) == {nil, nil}
    end

    test "a known 20-close example" do
      # today window 102..121 -> 111.5; yesterday window 101..120 -> 110.5
      {sma, slope} = Regime.sma_and_slope(decimals(101..120), Decimal.new(121), 20)

      assert Decimal.equal?(sma, Decimal.new("111.5"))
      assert Decimal.equal?(slope, Decimal.new("1"))
    end

    test "uses only the trailing window of a longer history" do
      # today window 7..26 -> 16.5; yesterday window 6..25 -> 15.5
      {sma, slope} = Regime.sma_and_slope(decimals(1..25), Decimal.new(26), 20)

      assert Decimal.equal?(sma, Decimal.new("16.5"))
      assert Decimal.equal?(slope, Decimal.new("1"))
    end

    test "rounds the SMA and slope to 8 decimal places" do
      # today window [0, 0, 2] -> 2/3; yesterday window [0, 0, 0] -> 0
      {sma, slope} = Regime.sma_and_slope(decimals([0, 0, 0]), Decimal.new(2), 3)

      assert Decimal.to_string(sma) == "0.66666667"
      assert Decimal.to_string(slope) == "0.66666667"
    end
  end

  describe "channel/3" do
    defp closes(values), do: Enum.map(values, &Decimal.new/1)

    test "breakout: 1 above the high, -1 below the low, 0 inside" do
      channel = closes(["10", "12", "11", "14", "13"])

      assert Regime.channel(channel, Decimal.new("14.01"), "breakout") == 1
      assert Regime.channel(channel, Decimal.new("9.99"), "breakout") == -1
      assert Regime.channel(channel, Decimal.new("12.5"), "breakout") == 0
    end

    test "breakout: equalling the high or low is not a breakout" do
      channel = closes(["10", "12", "14"])

      assert Regime.channel(channel, Decimal.new("14"), "breakout") == 0
      assert Regime.channel(channel, Decimal.new("10"), "breakout") == 0
    end

    test "position: where live sits between low and high" do
      channel = closes(["10", "12", "14"])

      assert Decimal.equal?(
               Regime.channel(channel, Decimal.new("13"), "position"),
               Decimal.new("0.75")
             )
    end

    test "position: clamped to 0..1 outside the channel" do
      channel = closes(["10", "12", "14"])

      assert Decimal.equal?(
               Regime.channel(channel, Decimal.new("20"), "position"),
               Decimal.new(1)
             )

      assert Decimal.equal?(Regime.channel(channel, Decimal.new("5"), "position"), Decimal.new(0))
    end

    test "position: nil for a flat channel" do
      assert Regime.channel(closes(["10", "10", "10"]), Decimal.new("11"), "position") == nil
    end

    test "position: rounds to 8 decimal places" do
      # (11 - 10) / (13 - 10) = 1/3; (12 - 10) / 3 = 2/3
      channel = closes(["10", "13"])

      assert Decimal.to_string(Regime.channel(channel, Decimal.new("11"), "position")) ==
               "0.33333333"

      assert Decimal.to_string(Regime.channel(channel, Decimal.new("12"), "position")) ==
               "0.66666667"
    end
  end

  describe "sessions_in_state/3" do
    defp decs(xs), do: Enum.map(xs, &Decimal.new(to_string(&1)))

    test "counts the closes in the last call, signed; chop is 0" do
      flat = List.duplicate(100, 10)

      assert Regime.sessions_in_state(decs(flat ++ [101, 102, 103]), 5, 0) == 3
      assert Regime.sessions_in_state(decs(flat ++ [101, 102, 103, 90]), 5, 0) == -1
      assert Regime.sessions_in_state(decs(flat), 5, 0) == 0
    end

    test "nil with no more than sma_days closes" do
      assert Regime.sessions_in_state(decs(List.duplicate(100, 5)), 5, 0) == nil
      assert Regime.sessions_in_state([], 5, 0) == nil
    end

    test "the hysteresis carries from close to close" do
      # 101 calls up; 100.95 is still above a rising SMA, and 100.4 is below
      # the SMA but within the margin, so the up call holds for 3 sessions.
      closes = decs(List.duplicate(100, 10) ++ [101, 100.95, 100.4])

      assert Regime.sessions_in_state(closes, 5, 0) == 0
      assert Regime.sessions_in_state(closes, 5, 50) == 3
    end

    test "accepts a float hysteresis_bps, as live uses 1.5" do
      closes = decs(List.duplicate(100, 25) ++ [101, 102, 103])

      assert Regime.sessions_in_state(closes, 20, 1.5) == 3
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

  describe "stable_vol_state/5" do
    @bands {Decimal.new("16.0"), Decimal.new("19.0")}

    defp vol(previous, vix) do
      new = Regime.classify_vol_absolute(vix, @bands)
      Regime.stable_vol_state(new, previous, vix, @bands)
    end

    test "no memory, or no change, returns new" do
      assert vol(nil, 16.5) == :normal
      assert vol(:normal, 17.0) == :normal
    end

    test "calm <-> normal uses the low edge in both directions" do
      assert vol(:calm, 16.5) == :calm
      assert vol(:calm, 17.5) == :normal
      assert vol(:normal, 15.5) == :normal
      assert vol(:normal, 14.5) == :calm
    end

    test "normal <-> stressed uses the high edge in both directions" do
      assert vol(:normal, 19.5) == :normal
      assert vol(:normal, 20.5) == :stressed
      assert vol(:stressed, 18.5) == :stressed
      assert vol(:stressed, 17.5) == :normal
    end

    test "a two-step jump uses the edge on new's side" do
      assert vol(:calm, 19.5) == :calm
      assert vol(:calm, 20.5) == :stressed
      assert vol(:stressed, 15.5) == :stressed
      assert vol(:stressed, 14.5) == :calm
    end

    test "margin is configurable" do
      assert Regime.stable_vol_state(:normal, :calm, 16.5, @bands, 0.25) == :normal
    end
  end

  describe "stable_trend_state/6" do
    # SMA 700: 0.1% = 0.7, 0.3% = 2.1; the default price deadband is 1.75.
    @sma Decimal.new("700")

    defp trend(previous, price_pct, slope, opts \\ []) do
      price = @sma |> Decimal.mult(Decimal.add(1, Decimal.from_float(price_pct / 100)))
      new = Regime.classify_trend(price, @sma, slope)
      Regime.stable_trend_state(new, previous, price, @sma, slope, opts)
    end

    test "price within 0.25% of the SMA holds; beyond it flips" do
      # up -> chop on price
      assert trend(:up, -0.1, 1.0) == :up
      assert trend(:up, -0.3, 1.0) == :chop
      # chop -> up / down on price
      assert trend(:chop, 0.1, 1.0) == :chop
      assert trend(:chop, 0.3, 1.0) == :up
      assert trend(:chop, -0.1, -1.0) == :chop
      assert trend(:chop, -0.3, -1.0) == :down
      # down -> chop on price
      assert trend(:down, 0.1, -1.0) == :down
      assert trend(:down, 0.3, -1.0) == :chop
    end

    test "slope within 0.10 holds; beyond it flips" do
      assert trend(:up, 2.0, -0.02) == :up
      assert trend(:up, 2.0, -0.15) == :chop
      assert trend(:chop, 2.0, 0.02) == :chop
      assert trend(:chop, 2.0, 0.15) == :up
      assert trend(:down, -2.0, 0.02) == :down
      assert trend(:down, -2.0, 0.15) == :chop
      assert trend(:chop, -2.0, -0.02) == :chop
      assert trend(:chop, -2.0, -0.15) == :down
    end

    test "up -> down only part-way lands on chop" do
      assert trend(:up, -2.0, -0.05) == :chop
      assert trend(:up, -2.0, -0.15) == :down
      assert trend(:down, 2.0, 0.05) == :chop
      assert trend(:down, 2.0, 0.15) == :up
    end

    test "from chop, a small move never classifies as the opposite of new" do
      # new :up (above SMA, positive slope) but both inside the deadband:
      # biasing toward :down would classify :down; it must hold :chop.
      assert trend(:chop, 0.1, 0.02) == :chop
      assert trend(:chop, -0.1, -0.02) == :chop
    end

    test "margins are configurable" do
      assert trend(:chop, 0.1, 1.0, price_margin_pct: 0.0005) == :up
      assert trend(:up, 2.0, -0.02, slope_margin: 0.01) == :chop
    end

    test "nil handling" do
      assert Regime.stable_trend_state(nil, :up, 700, 700, 0.1) == nil
      assert Regime.stable_trend_state(:down, nil, 690, 700, -0.5) == :down
      assert Regime.stable_trend_state(:down, :up, 690, nil, nil) == :down
      assert Regime.stable_trend_state(:down, :up, 690, 700, nil) == :down
      assert Regime.stable_trend_state(:up, :up, 701, 700, 0.5) == :up
    end
  end

  describe "trend_in_deadband?/3" do
    test "true within 0.25% of the SMA, inclusive" do
      assert Regime.trend_in_deadband?(701, 700)
      assert Regime.trend_in_deadband?(Decimal.new("701.75"), 700)
      refute Regime.trend_in_deadband?(Decimal.new("701.76"), 700)
      refute Regime.trend_in_deadband?(698, 700)
      assert Regime.trend_in_deadband?(698, 700, price_margin_pct: 0.005)
    end

    test "nil for missing inputs" do
      assert Regime.trend_in_deadband?(nil, 700) == nil
      assert Regime.trend_in_deadband?(700, nil) == nil
    end
  end
end
