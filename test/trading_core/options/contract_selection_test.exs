defmodule TradingCore.Options.ContractSelectionTest do
  use ExUnit.Case, async: true

  alias TradingCore.Options.ContractSelection, as: CS

  @today ~D[2026-09-23]
  @feb "20270219"
  @mar "20270319"
  @apr "20270416"

  defp atm(overrides \\ %{}) do
    Map.merge(
      %{
        "strike_selection" => "atm_offset",
        "expiry_selection" => "dte_target",
        "dte_target" => 120,
        "right" => "C"
      },
      overrides
    )
  end

  defp pairs({:ok, contracts}), do: Enum.map(contracts, &{&1.expiry, &1.strike})

  describe "third_friday_on_or_after/2" do
    test "120 DTE from 2026-09-23 lands on Feb 2027's third Friday" do
      assert CS.third_friday_on_or_after(@today, 120) == ~D[2027-02-19]
    end

    test "one day after a third Friday is the next month's" do
      assert CS.third_friday_on_or_after(~D[2027-02-19], 1) == ~D[2027-03-19]
    end

    test "a third Friday itself counts at 0 DTE" do
      assert CS.third_friday_on_or_after(~D[2027-02-19], 0) == ~D[2027-02-19]
    end
  end

  describe "expiry_candidates/2" do
    test "dte_target: the target third Friday, then the next two" do
      assert CS.expiry_candidates(atm(), @today) == {:ok, [@feb, @mar, @apr]}
    end

    test "dte_target defaults to 45 days" do
      # 2026-09-23 + 45 = 2026-11-07 -> third Friday 2026-11-20.
      assert {:ok, ["20261120", "20261218", "20270115"]} =
               CS.expiry_candidates(Map.delete(atm(), "dte_target"), @today)
    end

    test "a fixed expiry never falls through" do
      config = %{"expiry_selection" => "fixed", "fixed_expiry" => "20271217"}
      assert CS.expiry_candidates(config, @today) == {:ok, ["20271217"]}
    end

    test "no usable expiry is unsupported" do
      assert CS.expiry_candidates(%{"expiry_selection" => "weekly"}, @today) ==
               {:error, :unsupported_leg_config}

      assert CS.expiry_candidates(atm(%{"dte_target" => "120"}), @today) ==
               {:error, :unsupported_leg_config}
    end
  end

  describe "holiday third Fridays" do
    test "a holiday third Friday expires the Thursday before" do
      # Juneteenth 2026 is the third Friday of June.
      assert CS.monthly_expiry(~D[2026-06-19]) == ~D[2026-06-18]
      # Juneteenth 2027 is a Saturday, observed Friday 2027-06-18.
      assert CS.monthly_expiry(~D[2027-06-18]) == ~D[2027-06-17]
      assert CS.monthly_expiry(~D[2026-07-17]) == ~D[2026-07-17]
    end

    test "a dte_target landing on June 2026 probes Thursday 20260618" do
      # 2026-05-01 + 45 = 2026-06-15 -> third Friday 2026-06-19 (holiday).
      config = %{"expiry_selection" => "dte_target", "dte_target" => 45}

      assert CS.expiry_candidates(config, ~D[2026-05-01]) ==
               {:ok, ["20260618", "20260717", "20260821"]}
    end

    # The chain runs on the unadjusted third Fridays. Chaining from the
    # adjusted Thursday would find the same month's Friday again, so a
    # holiday month would fall through to itself.
    test "a holiday first month falls through to the NEXT month" do
      config = %{"expiry_selection" => "dte_target", "dte_target" => 45}

      assert {:ok, ["20260618", second, third]} =
               CS.expiry_candidates(config, ~D[2026-05-01])

      assert second == "20260717"
      assert third == "20260821"
    end

    test "a holiday in a fall-through month is adjusted too" do
      # 2026-04-01 + 44 = 2026-05-15 -> May, then June (holiday), then July.
      config = %{"expiry_selection" => "dte_target", "dte_target" => 44}

      assert CS.expiry_candidates(config, ~D[2026-04-01]) ==
               {:ok, ["20260515", "20260618", "20260717"]}
    end
  end

  describe "strike_increment/2" do
    test "measured symbols use their table entry, whatever the spot" do
      for {symbol, increment} <- [
            {"SPY", 5.0},
            {"QQQ", 5.0},
            {"XLF", 1.0},
            {"NVDA", 5.0},
            {"TSLA", 5.0},
            {"SMH", 5.0},
            {"SOXL", 5.0},
            {"AMD", 10.0},
            {"MU", 10.0},
            {"TLT", 1.0},
            {"XLE", 1.0},
            {"RSP", 5.0}
          ] do
        assert CS.strike_increment(symbol) == increment
        assert CS.strike_increment(symbol, 3.0) == increment
        assert CS.strike_increment(symbol, 5_000.0) == increment
      end
    end

    test "unmeasured symbols guess from spot, coarsest plausible grid" do
      assert CS.strike_increment("ZZZZ", 24.99) == 1.0
      assert CS.strike_increment("ZZZZ", 25) == 5.0
      assert CS.strike_increment("ZZZZ", 199.99) == 5.0
      assert CS.strike_increment("ZZZZ", 200) == 10.0
      assert CS.strike_increment("ZZZZ", 1_500.0) == 10.0
      assert CS.strike_increment("XLK", 275.0) == 10.0
    end

    test "with no spot an unmeasured symbol falls back to $1" do
      assert CS.strike_increment("ZZZZ") == 1.0
      assert CS.strike_increment("ZZZZ", nil) == 1.0
    end
  end

  describe "candidates/4, atm_offset" do
    test "rounded strike on every expiry first, then neighbours on the first" do
      assert pairs(CS.candidates("SPY", atm(), 768.0, @today)) == [
               {@feb, 770.0},
               {@mar, 770.0},
               {@apr, 770.0},
               {@feb, 775.0},
               {@feb, 765.0}
             ]
    end

    test "every candidate carries the right" do
      {:ok, contracts} = CS.candidates("SPY", atm(%{"right" => "P"}), 768.0, @today)
      assert Enum.all?(contracts, &(&1.right == "P"))
      assert length(contracts) == 5
    end

    test "a single fixed expiry keeps the three-strike probe" do
      config = atm(%{"expiry_selection" => "fixed", "fixed_expiry" => @feb})

      assert pairs(CS.candidates("QQQ", config, 744.0, @today)) ==
               [{@feb, 745.0}, {@feb, 750.0}, {@feb, 740.0}]
    end

    test "strike_offset shifts the target in dollars" do
      assert [{@feb, 780.0} | _] =
               pairs(CS.candidates("SPY", atm(%{"strike_offset" => 10}), 768.0, @today))

      assert [{@feb, 760.0} | _] =
               pairs(CS.candidates("SPY", atm(%{"strike_offset" => -10}), 768.0, @today))
    end

    test "a .5 boundary rounds half away from zero" do
      assert [{@feb, 770.0} | _] = pairs(CS.candidates("SPY", atm(), 767.5, @today))
      assert [{@feb, 765.0} | _] = pairs(CS.candidates("SPY", atm(), 762.5, @today))
      assert [{@feb, 765.0} | _] = pairs(CS.candidates("SPY", atm(), 767.49, @today))
      assert [{@feb, 54.0} | _] = pairs(CS.candidates("XLF", atm(), 53.5, @today))
    end

    test "XLF uses the $1 grid" do
      assert pairs(CS.candidates("XLF", atm(), 53.3, @today)) == [
               {@feb, 53.0},
               {@mar, 53.0},
               {@apr, 53.0},
               {@feb, 54.0},
               {@feb, 52.0}
             ]
    end

    # Spots from IBKR on 2026-10-02 (TLT/XLE: trading_options_sim, 10-01;
    # RSP: 2026-10-05 close). The first candidate must be a strike
    # on the measured Nov-2026 grid, and so must its neighbours.
    for {symbol, spot, first, up, down} <- [
          {"NVDA", 231.4, 230.0, 235.0, 225.0},
          {"TSLA", 355.0, 355.0, 360.0, 350.0},
          {"SMH", 618.0, 620.0, 625.0, 615.0},
          {"SOXL", 154.0, 155.0, 160.0, 150.0},
          {"AMD", 618.0, 620.0, 630.0, 610.0},
          {"MU", 1088.0, 1090.0, 1100.0, 1080.0},
          {"TLT", 78.3, 78.0, 79.0, 77.0},
          {"XLE", 62.4, 62.0, 63.0, 61.0},
          {"RSP", 211.8, 210.0, 215.0, 205.0},
          {"RSP", 213.0, 215.0, 220.0, 210.0}
        ] do
      @symbol symbol
      @spot spot
      @expected [first, first, first, up, down]
      test "#{symbol} at #{spot} probes on-grid strikes" do
        assert {:ok, contracts} = CS.candidates(@symbol, atm(), @spot, @today)
        assert Enum.map(contracts, & &1.strike) == @expected
      end
    end

    test "RSP never probes a strike off the $5 grid" do
      # 211-213 were :not_found live on 2026-10-05; only multiples of 5 list.
      for spot <- Enum.map(2000..2200, &(&1 / 10)) do
        assert {:ok, contracts} = CS.candidates("RSP", atm(), spot, @today)

        assert Enum.all?(contracts, &(rem(trunc(&1.strike * 100), 500) == 0)),
               "RSP at #{spot}: #{inspect(Enum.map(contracts, & &1.strike))}"
      end
    end

    test "an unmeasured symbol rounds to its price-based grid" do
      assert [{@feb, 240.0} | _] = pairs(CS.candidates("ZZZZ", atm(), 236.0, @today))
      assert [{@feb, 85.0} | _] = pairs(CS.candidates("ZZZZ", atm(), 83.0, @today))
      assert [{@feb, 12.0} | _] = pairs(CS.candidates("ZZZZ", atm(), 12.3, @today))
    end

    test "strikes at or below zero are never probed" do
      config = atm(%{"strike_offset" => -5})

      assert pairs(CS.candidates("XLF", config, 3.0, @today)) == []

      assert pairs(CS.candidates("XLF", atm(%{"strike_offset" => -2}), 3.0, @today)) == [
               {@feb, 1.0},
               {@mar, 1.0},
               {@apr, 1.0},
               {@feb, 2.0}
             ]
    end

    test "no spot is :no_spot" do
      assert CS.candidates("SPY", atm(), nil, @today) == {:error, :no_spot}
      assert CS.candidates("SPY", atm(), 0.0, @today) == {:error, :no_spot}
    end

    test "an unsupported right or offset is rejected" do
      for config <- [atm(%{"right" => "either"}), atm(%{"strike_offset" => "10"})] do
        assert CS.candidates("SPY", config, 768.0, @today) == {:error, :unsupported_leg_config}
      end
    end
  end

  describe "candidates/4, fixed_strike" do
    defp fixed(overrides) do
      Map.merge(
        %{
          "strike_selection" => "fixed_strike",
          "expiry_selection" => "fixed",
          "fixed_expiry" => "20271231",
          "fixed_strike" => "762.00",
          "right" => "C"
        },
        overrides
      )
    end

    test "one literal contract; a string strike is parsed and spot ignored" do
      assert CS.candidates("SPY", fixed(%{}), nil, @today) ==
               {:ok, [%{expiry: "20271231", strike: 762.0, right: "C"}]}
    end

    test "numeric strikes agree with string ones" do
      for strike <- [762, 762.0, "762"] do
        assert {:ok, [%{strike: 762.0}]} =
                 CS.candidates("SPY", fixed(%{"fixed_strike" => strike}), nil, @today)
      end
    end

    test "leaps is treated like fixed, as in trading_options_sim" do
      assert {:ok, [%{expiry: "20271231"}]} =
               CS.candidates("SPY", fixed(%{"expiry_selection" => "leaps"}), nil, @today)
    end

    test "unsupported shapes are rejected" do
      for config <- [
            fixed(%{"right" => "either"}),
            fixed(%{"expiry_selection" => "dte_target"}),
            fixed(%{"fixed_strike" => "0"}),
            fixed(%{"fixed_strike" => -5}),
            fixed(%{"fixed_strike" => "abc"}),
            Map.delete(fixed(%{}), "fixed_expiry"),
            %{"strike_selection" => "delta_target"}
          ] do
        assert CS.candidates("SPY", config, 768.0, @today) == {:error, :unsupported_leg_config}
      end
    end
  end
end
