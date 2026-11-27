defmodule TradingCore.Options.SkewTest do
  use ExUnit.Case, async: true

  alias TradingCore.Options.Skew

  doctest TradingCore.Options.Skew

  @now ~U[2026-11-26 15:00:00Z]
  @stale 120_000

  defp leg(attrs) do
    Map.merge(
      %{
        strike: 600.0,
        right: "P",
        bid: 5.0,
        ask: 5.2,
        quote_at: @now,
        delayed: false,
        iv: 0.2,
        delta: -0.25,
        und: 600.0,
        model_at: @now
      },
      Map.new(attrs)
    )
  end

  defp normal_cdf(x), do: 0.5 * (1 + :math.erf(x / :math.sqrt(2)))

  # Black-Scholes delta with forward = spot, r = 0.
  defp bs_delta(spot, k, iv, t, right) do
    d1 = (:math.log(spot / k) + iv * iv * t / 2) / (iv * :math.sqrt(t))
    if right == "C", do: normal_cdf(d1), else: normal_cdf(d1) - 1
  end

  describe "select_expiry/3" do
    test "the monthly in range, else the closest; ties go longer-dated" do
      # Dec 18 is 22 DTE (8 short), Jan 15 is 50 (5 over).
      assert Skew.select_expiry(~D[2026-11-26], 30, 45) == ~D[2027-01-15]
      assert Skew.select_expiry(~D[2026-11-26], 20, 30) == ~D[2026-12-18]
      # Dec 18 is 22, Jan 15 is 50: both 14 from 36..36.
      assert Skew.select_expiry(~D[2026-11-26], 36, 36) == ~D[2027-01-15]
    end

    test "only expiries after today; holiday Fridays move to Thursday" do
      assert Skew.select_expiry(~D[2026-11-20], 1, 5) != ~D[2026-11-20]
      # Juneteenth 2026-06-19 is the third Friday.
      assert Skew.select_expiry(~D[2026-06-01], 15, 20) == ~D[2026-06-18]
    end
  end

  test "years_to_expiry/2 floors at one day" do
    assert Skew.years_to_expiry(~D[2027-01-15], ~D[2026-11-26]) == 50 / 365
    assert Skew.years_to_expiry(~D[2026-11-26], ~D[2026-11-26]) == 1 / 365
  end

  describe "bracket/2" do
    test "lo <= x < hi on the grid" do
      assert Skew.bracket(767.3, 5) == {765.0, 770.0}
      assert Skew.bracket(770, 5) == {770.0, 775.0}
      assert Skew.bracket(7.7, 0.1) == {7.7, 7.8}
      assert Skew.bracket(601.49, 1) == {601.0, 602.0}
    end
  end

  describe "target_strike/5" do
    for right <- ["P", "C"], delta <- [0.25, 0.10] do
      test "#{right} strike round-trips to |delta| = #{delta}" do
        {spot, iv, t} = {767.0, 0.18, 40 / 365}
        k = Skew.target_strike(spot, iv, t, unquote(right), unquote(delta))
        assert_in_delta abs(bs_delta(spot, k, iv, t, unquote(right))), unquote(delta), 1.0e-9
      end
    end

    test "puts below spot, calls above" do
      assert Skew.target_strike(600, 0.2, 0.1, "P") < 600
      assert Skew.target_strike(600, 0.2, 0.1, "C") > 600
    end
  end

  describe "unusable_reason/3" do
    test "nil when usable" do
      assert Skew.unusable_reason(leg([]), @now, @stale) == nil
      assert Skew.usable?(leg([]), @now, @stale)
      assert Skew.usable?(leg(bid: 5.2, ask: 5.2), @now, @stale)
    end

    test "each reason" do
      old = DateTime.add(@now, -(@stale + 1), :millisecond)

      for {attrs, reason} <- [
            {[bid: 0], :no_two_sided_quote},
            {[ask: nil], :no_two_sided_quote},
            {[bid: 5.3, ask: 5.2], :crossed},
            {[delayed: true], :delayed},
            {[quote_at: old], :stale_quote},
            {[quote_at: nil], :stale_quote},
            {[model_at: old], :stale_model},
            {[iv: 0], :no_iv},
            {[iv: 5.0], :no_iv},
            {[iv: nil], :no_iv},
            {[delta: 0], :no_delta},
            {[delta: -1.5], :no_delta},
            {[delta: nil], :no_delta}
          ] do
        assert Skew.unusable_reason(leg(attrs), @now, @stale) == reason, inspect(attrs)
        refute Skew.usable?(leg(attrs), @now, @stale)
      end

      assert Skew.unusable_reason(nil, @now, @stale) == :no_leg
    end

    test "the first failing check wins" do
      assert Skew.unusable_reason(leg(bid: 0, delayed: true, iv: 0), @now, @stale) ==
               :no_two_sided_quote
    end

    test "exactly stale_ms old is still fresh" do
      at = DateTime.add(@now, -@stale, :millisecond)
      assert Skew.usable?(leg(quote_at: at, model_at: at), @now, @stale)
    end
  end

  describe "atm_put_call_spread/5" do
    defp atm_legs(attrs \\ %{}) do
      %{
        "P600" => leg(Map.get(attrs, "P600", strike: 600.0, right: "P", iv: 0.21)),
        "C600" => leg(Map.get(attrs, "C600", strike: 600.0, right: "C", iv: 0.19, delta: 0.5)),
        "P605" => leg(strike: 605.0, right: "P", iv: 0.20),
        "C605" => leg(strike: 605.0, right: "C", iv: 0.185, delta: 0.45)
      }
    end

    test "put IV minus call IV at the nearest strike" do
      assert {:ok, s} = Skew.atm_put_call_spread(atm_legs(), 601.0, [600.0, 605.0], @now, @stale)
      assert_in_delta s, 0.02, 1.0e-12

      assert {:ok, s} = Skew.atm_put_call_spread(atm_legs(), 604.0, [600.0, 605.0], @now, @stale)
      assert_in_delta s, 0.015, 1.0e-12
    end

    test "a tie goes to the lower strike" do
      assert {:ok, s} = Skew.atm_put_call_spread(atm_legs(), 602.5, [600.0, 605.0], @now, @stale)
      assert_in_delta s, 0.02, 1.0e-12
    end

    test "no fallback to the other strike" do
      legs = atm_legs(%{"C600" => [strike: 600.0, right: "C", delayed: true, delta: 0.5]})

      assert Skew.atm_put_call_spread(legs, 601.0, [600.0, 605.0], @now, @stale) ==
               {:error, {:call, 600.0, :delayed}}

      legs = Map.delete(atm_legs(), "P600")

      assert Skew.atm_put_call_spread(legs, 601.0, [600.0, 605.0], @now, @stale) ==
               {:error, {:put, 600.0, :no_leg}}
    end
  end

  describe "iv_at_delta/2" do
    test "linear in |delta|, in either leg order" do
      a = leg(delta: -0.20, iv: 0.22)
      b = leg(delta: -0.30, iv: 0.24)
      assert {:ok, iv} = Skew.iv_at_delta([a, b], 0.25)
      assert_in_delta iv, 0.23, 1.0e-12
      assert {:ok, ^iv} = Skew.iv_at_delta([b, a], 0.25)
    end

    test "the ends are inclusive" do
      a = leg(delta: 0.25, iv: 0.17)
      b = leg(delta: 0.30, iv: 0.18)
      assert Skew.iv_at_delta([a, b], 0.25) == {:ok, 0.17}
      assert Skew.iv_at_delta([a, b], 0.30) == {:ok, 0.18}
      assert Skew.iv_at_delta([a, a], 0.25) == {:ok, 0.17}
    end

    test "outside the bracket" do
      a = leg(delta: 0.26, iv: 0.17)
      b = leg(delta: 0.30, iv: 0.18)
      assert Skew.iv_at_delta([a, b], 0.25) == {:error, :outside_bracket}
      assert Skew.iv_at_delta([b, b], 0.25) == {:error, :outside_bracket}
    end
  end

  describe "risk_reversal/5" do
    defp puts, do: [leg(delta: -0.20, iv: 0.24), leg(delta: -0.30, iv: 0.26)]

    defp calls,
      do: [leg(right: "C", delta: 0.20, iv: 0.16), leg(right: "C", delta: 0.30, iv: 0.18)]

    test "put25 minus call25" do
      assert {:ok, rr} = Skew.risk_reversal(puts(), calls(), 0.25, @now, @stale)
      assert_in_delta rr, 0.25 - 0.17, 1.0e-12
    end

    test "errors are tagged with the wing, put first" do
      assert Skew.risk_reversal([nil, hd(puts())], [nil, nil], 0.25, @now, @stale) ==
               {:error, {:put, :no_leg}}

      assert Skew.risk_reversal(puts(), [hd(calls()), leg(right: "C", iv: 0)], 0.25, @now, @stale) ==
               {:error, {:call, :no_iv}}

      assert Skew.risk_reversal(puts(), calls(), 0.35, @now, @stale) ==
               {:error, {:put, :outside_bracket}}

      assert Skew.risk_reversal(puts(), [hd(calls())], 0.25, @now, @stale) ==
               {:error, {:call, :no_leg}}
    end
  end

  describe "wing_bracket/3" do
    @ctx %{
      now: @now,
      stale_ms: @stale,
      iv_seed: 0.2,
      spot: 600.0,
      t: 40 / 365,
      right: "P",
      delta: 0.25,
      step: 5.0
    }

    test "nil aims from the seed IV" do
      k = Skew.target_strike(600.0, 0.2, 40 / 365, "P")
      assert Skew.wing_bracket(nil, [], @ctx) == Skew.bracket(k, 5.0)
    end

    test "keeps a bracket that straddles the target" do
      legs = [leg(strike: 570.0, delta: -0.22), leg(strike: 575.0, delta: -0.27)]
      assert Skew.wing_bracket({570.0, 575.0}, legs, @ctx) == {570.0, 575.0}
    end

    test "keeps the bracket while legs wait for ticks" do
      legs = [leg(strike: 570.0, delta: -0.10), nil]
      assert Skew.wing_bracket({570.0, 575.0}, legs, @ctx) == {570.0, 575.0}

      legs = [leg(strike: 570.0, delta: -0.10), leg(strike: 575.0, delta: -0.12, bid: 0)]
      assert Skew.wing_bracket({570.0, 575.0}, legs, @ctx) == {570.0, 575.0}
    end

    test "re-aims from the legs' mean IV when outside" do
      # Legs at IV 0.35 put the 25-delta strike well below a 590/595 wing.
      legs = [
        leg(strike: 590.0, delta: -0.35, iv: 0.35),
        leg(strike: 595.0, delta: -0.40, iv: 0.35)
      ]

      expected = Skew.bracket(Skew.target_strike(600.0, 0.35, 40 / 365, "P"), 5.0)
      assert expected != {590.0, 595.0}
      assert Skew.wing_bracket({590.0, 595.0}, legs, @ctx) == expected
    end

    test "steps one grid step when the re-aim lands on the same bracket" do
      current = Skew.wing_bracket(nil, [], @ctx)
      {lo, hi} = current

      # Live put deltas both below target: need a higher strike.
      below = [leg(strike: lo, delta: -0.18), leg(strike: hi, delta: -0.22)]
      assert Skew.wing_bracket(current, below, @ctx) == {lo + 5.0, hi + 5.0}

      # Both above target: lower strike.
      above = [leg(strike: lo, delta: -0.28), leg(strike: hi, delta: -0.32)]
      assert Skew.wing_bracket(current, above, @ctx) == {lo - 5.0, hi - 5.0}
    end

    test "the step goes the other way for calls" do
      ctx = %{@ctx | right: "C"}
      current = Skew.wing_bracket(nil, [], ctx)
      {lo, hi} = current

      below = [leg(right: "C", strike: lo, delta: 0.22), leg(right: "C", strike: hi, delta: 0.18)]
      assert Skew.wing_bracket(current, below, ctx) == {lo - 5.0, hi - 5.0}

      above = [leg(right: "C", strike: lo, delta: 0.32), leg(right: "C", strike: hi, delta: 0.28)]
      assert Skew.wing_bracket(current, above, ctx) == {lo + 5.0, hi + 5.0}
    end
  end

  describe "atm_bracket/3" do
    test "keeps the bracket while spot is inside, inclusive" do
      assert Skew.atm_bracket({600.0, 605.0}, 605.0, 5.0) == {600.0, 605.0}
      assert Skew.atm_bracket({600.0, 605.0}, 600.0, 5.0) == {600.0, 605.0}
    end

    test "re-brackets outside, or from nil" do
      assert Skew.atm_bracket({600.0, 605.0}, 606.0, 5.0) == {605.0, 610.0}
      assert Skew.atm_bracket(nil, 601.0, 5.0) == {600.0, 605.0}
    end
  end
end
