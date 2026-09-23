defmodule TradingCore.RuleEngineTest do
  use ExUnit.Case, async: true

  alias TradingCore.RuleEngine

  describe "evaluate/2 — vacuous cases" do
    test "nil rule is always satisfied" do
      assert RuleEngine.evaluate(nil, %{})
    end

    test "empty map rule is always satisfied" do
      assert RuleEngine.evaluate(%{}, %{"anything" => 1})
    end
  end

  describe "evaluate/2 — single condition, literal value" do
    test "gt passes when signal is greater than value" do
      rule = %{"signal" => "vix_last", "op" => "gt", "value" => 15}
      assert RuleEngine.evaluate(rule, %{"vix_last" => 16.2})
    end

    test "gt fails when signal is not greater than value" do
      rule = %{"signal" => "vix_last", "op" => "gt", "value" => 15}
      refute RuleEngine.evaluate(rule, %{"vix_last" => 15})
    end

    test "lt passes when signal is less than value" do
      rule = %{"signal" => "vix_last", "op" => "lt", "value" => 18}
      assert RuleEngine.evaluate(rule, %{"vix_last" => 16.2})
    end

    test "gte passes at exact equality" do
      rule = %{"signal" => "spy_return_5m", "op" => "gte", "value" => 0}
      assert RuleEngine.evaluate(rule, %{"spy_return_5m" => 0})
    end

    test "lte passes at exact equality" do
      rule = %{"signal" => "spy_return_5m", "op" => "lte", "value" => 0}
      assert RuleEngine.evaluate(rule, %{"spy_return_5m" => 0})
    end

    test "eq passes only on exact match" do
      rule = %{"signal" => "regime", "op" => "eq", "value" => 1}
      assert RuleEngine.evaluate(rule, %{"regime" => 1})
      refute RuleEngine.evaluate(rule, %{"regime" => 2})
    end
  end

  describe "evaluate/2 — value_signal comparand" do
    test "compares one named signal against another" do
      rule = %{
        "signal" => "current_price",
        "op" => "lte",
        "value_signal" => "run_stop_loss_price"
      }

      assert RuleEngine.evaluate(rule, %{
               "current_price" => Decimal.new("90"),
               "run_stop_loss_price" => Decimal.new("95")
             })

      refute RuleEngine.evaluate(rule, %{
               "current_price" => Decimal.new("100"),
               "run_stop_loss_price" => Decimal.new("95")
             })
    end
  end

  describe "evaluate/2 — missing signals fail closed" do
    test "condition referencing a signal not in the snapshot is not met" do
      rule = %{"signal" => "vix_last", "op" => "lt", "value" => 18}
      refute RuleEngine.evaluate(rule, %{})
    end

    test "value_signal referencing a signal not in the snapshot is not met" do
      rule = %{
        "signal" => "current_price",
        "op" => "lte",
        "value_signal" => "run_stop_loss_price"
      }

      refute RuleEngine.evaluate(rule, %{"current_price" => Decimal.new("90")})
    end
  end

  describe "evaluate/2 — combinators" do
    test "all requires every condition to pass" do
      rule = %{
        "all" => [
          %{"signal" => "spy_return_5m", "op" => "gt", "value" => 0},
          %{"signal" => "vix_last", "op" => "lt", "value" => 18}
        ]
      }

      assert RuleEngine.evaluate(rule, %{"spy_return_5m" => 0.4, "vix_last" => 16.2})
      refute RuleEngine.evaluate(rule, %{"spy_return_5m" => -0.1, "vix_last" => 16.2})
      refute RuleEngine.evaluate(rule, %{"spy_return_5m" => 0.4, "vix_last" => 22})
    end

    test "any requires at least one condition to pass" do
      rule = %{
        "any" => [
          %{"signal" => "current_price", "op" => "lte", "value_signal" => "run_stop_loss_price"},
          %{"signal" => "current_price", "op" => "gte", "value_signal" => "run_take_profit_price"}
        ]
      }

      snapshot = %{
        "run_stop_loss_price" => Decimal.new("95"),
        "run_take_profit_price" => Decimal.new("110")
      }

      assert RuleEngine.evaluate(rule, Map.put(snapshot, "current_price", Decimal.new("90")))
      assert RuleEngine.evaluate(rule, Map.put(snapshot, "current_price", Decimal.new("120")))
      refute RuleEngine.evaluate(rule, Map.put(snapshot, "current_price", Decimal.new("100")))
    end

    test "not inverts a condition" do
      rule = %{"not" => %{"signal" => "vix_last", "op" => "lt", "value" => 18}}

      assert RuleEngine.evaluate(rule, %{"vix_last" => 22})
      refute RuleEngine.evaluate(rule, %{"vix_last" => 16})
    end

    test "nested combinators compose" do
      rule = %{
        "all" => [
          %{"signal" => "spy_return_5m", "op" => "gt", "value" => 0},
          %{
            "any" => [
              %{"signal" => "vix_last", "op" => "lt", "value" => 18},
              %{"signal" => "regime", "op" => "eq", "value" => 1}
            ]
          }
        ]
      }

      assert RuleEngine.evaluate(rule, %{"spy_return_5m" => 0.4, "vix_last" => 22, "regime" => 1})
      refute RuleEngine.evaluate(rule, %{"spy_return_5m" => 0.4, "vix_last" => 22, "regime" => 2})
    end
  end

  describe "evaluate/2 — \"not\" fails closed on missing signals" do
    @volume_gt %{"signal" => "polygon_volume", "op" => "gt", "value" => 48_000}

    test "not over an absent key is false, not true" do
      refute RuleEngine.evaluate(%{"not" => @volume_gt}, %{})
    end

    test "not over a present key whose condition is false is true" do
      assert RuleEngine.evaluate(%{"not" => @volume_gt}, %{"polygon_volume" => 10_000})
    end

    test "not over an absent value_signal comparand is false" do
      rule = %{
        "not" => %{"signal" => "current_price", "op" => "lte", "value_signal" => "run_stop"}
      }

      refute RuleEngine.evaluate(rule, %{"current_price" => 90})
    end

    test "a nil value counts as absent under not" do
      refute RuleEngine.evaluate(%{"not" => @volume_gt}, %{"polygon_volume" => nil})
    end

    test "not inside all with an absent key fails the all" do
      rule = %{
        "all" => [
          %{"signal" => "vix_last", "op" => "lt", "value" => 18},
          %{"not" => @volume_gt}
        ]
      }

      refute RuleEngine.evaluate(rule, %{"vix_last" => 16})
      assert RuleEngine.evaluate(rule, %{"vix_last" => 16, "polygon_volume" => 10_000})
    end

    test "not inside any with an absent key does not carry the any" do
      rule = %{
        "any" => [
          %{"signal" => "vix_last", "op" => "gt", "value" => 30},
          %{"not" => @volume_gt}
        ]
      }

      refute RuleEngine.evaluate(rule, %{"vix_last" => 16})
      # A definitely-true leg still carries the any past an unknown one.
      assert RuleEngine.evaluate(rule, %{"vix_last" => 35})
    end

    test "not over all/any containing an absent key is false" do
      snapshot = %{"vix_last" => 16}
      vix_gt = %{"signal" => "vix_last", "op" => "gt", "value" => 30}

      refute RuleEngine.evaluate(%{"not" => %{"any" => [vix_gt, @volume_gt]}}, snapshot)
      # all of [true, unknown] is unknown, so its negation is too.
      vix_lt = %{"signal" => "vix_last", "op" => "lt", "value" => 18}
      refute RuleEngine.evaluate(%{"not" => %{"all" => [vix_lt, @volume_gt]}}, snapshot)
      # all of [false, unknown] is definitely false, so its negation passes.
      assert RuleEngine.evaluate(%{"not" => %{"all" => [vix_gt, @volume_gt]}}, snapshot)
    end

    test "not over a transition op whose prev_ key is missing is false" do
      rule = %{"not" => %{"signal" => "deriv", "op" => "sign_flip"}}

      refute RuleEngine.evaluate(rule, %{"deriv" => 0.5})
      assert RuleEngine.evaluate(rule, %{"deriv" => 0.5, "prev_deriv" => 0.4})
    end

    test "double negation over an absent key stays false" do
      refute RuleEngine.evaluate(%{"not" => %{"not" => @volume_gt}}, %{})

      assert RuleEngine.evaluate(%{"not" => %{"not" => @volume_gt}}, %{"polygon_volume" => 50_000})
    end

    test "not over a malformed condition is false" do
      refute RuleEngine.evaluate(%{"not" => %{"nonsense" => true}}, %{})

      refute RuleEngine.evaluate(%{"not" => %{"signal" => "vix_last", "op" => "lt"}}, %{
               "vix_last" => 16
             })

      refute RuleEngine.evaluate(
               %{"not" => %{"signal" => "vix_last", "op" => "between", "value" => 18}},
               %{"vix_last" => 16}
             )
    end

    test "not over a vacuous rule is false" do
      refute RuleEngine.evaluate(%{"not" => %{}}, %{})
    end
  end

  describe "evaluate/2 — malformed rules fail closed" do
    test "unrecognized op is not met" do
      rule = %{"signal" => "vix_last", "op" => "between", "value" => 18}
      refute RuleEngine.evaluate(rule, %{"vix_last" => 16})
    end

    test "condition missing both value and value_signal is not met" do
      rule = %{"signal" => "vix_last", "op" => "lt"}
      refute RuleEngine.evaluate(rule, %{"vix_last" => 16})
    end

    test "completely unrecognized shape is not met" do
      refute RuleEngine.evaluate(%{"nonsense" => true}, %{})
    end
  end

  describe "margin/2 — vacuous cases" do
    test "nil rule scores 1.0" do
      assert RuleEngine.margin(nil, %{}) == 1.0
    end

    test "empty map rule scores 1.0" do
      assert RuleEngine.margin(%{}, %{"anything" => 1}) == 1.0
    end
  end

  describe "margin/2 — single condition" do
    test "scores higher the further a passing condition clears its threshold" do
      rule = %{"signal" => "vix_last", "op" => "lt", "value" => 20}

      barely = RuleEngine.margin(rule, %{"vix_last" => 19})
      comfortably = RuleEngine.margin(rule, %{"vix_last" => 10})

      assert comfortably > barely
      assert barely > 0.0
    end

    test "clamps to 1.0 rather than growing unbounded on a huge blowout" do
      rule = %{"signal" => "vix_last", "op" => "lt", "value" => 20}
      assert RuleEngine.margin(rule, %{"vix_last" => -1_000_000}) == 1.0
    end

    test "eq is binary: 1.0 on exact match, 0.0 otherwise" do
      rule = %{"signal" => "regime", "op" => "eq", "value" => 1}
      assert RuleEngine.margin(rule, %{"regime" => 1}) == 1.0
      assert RuleEngine.margin(rule, %{"regime" => 2}) == 0.0
    end
  end

  describe "margin/2 — missing/malformed fails closed, same convention as evaluate/2" do
    test "condition referencing a signal not in the snapshot scores 0.0" do
      rule = %{"signal" => "vix_last", "op" => "lt", "value" => 18}
      assert RuleEngine.margin(rule, %{}) == 0.0
    end

    test "completely unrecognized shape scores 0.0" do
      assert RuleEngine.margin(%{"nonsense" => true}, %{}) == 0.0
    end
  end

  # A signal bus can emit nil while warming up. Before this was handled,
  # a present-with-nil key reached to_decimal/1 — which has clauses for
  # Decimal/float/integer/binary and none for nil — and raised
  # FunctionClauseError from inside whatever was evaluating. For the live
  # callers that is a periodic exit sweep, so one unlucky snapshot would
  # abort the whole sweep and take every other position's exit check with
  # it, rather than declining a single condition.
  describe "a nil value in the snapshot is treated as a missing signal" do
    test "evaluate/2 fails closed rather than raising" do
      rule = %{"signal" => "vix_last", "op" => "gt", "value" => 0}

      refute RuleEngine.evaluate(rule, %{"vix_last" => nil})
      # Identical to the absent-key answer.
      assert RuleEngine.evaluate(rule, %{"vix_last" => nil}) ==
               RuleEngine.evaluate(rule, %{})
    end

    test "a nil value_signal comparand fails closed rather than raising" do
      rule = %{"signal" => "price", "op" => "gt", "value_signal" => "run_stop"}

      refute RuleEngine.evaluate(rule, %{"price" => 100, "run_stop" => nil})
    end

    test "a nil rule literal fails closed rather than comparing against zero" do
      rule = %{"signal" => "vix_last", "op" => "gte", "value" => nil}

      refute RuleEngine.evaluate(rule, %{"vix_last" => 18})
    end

    test "margin/2 scores 0.0, matching its missing-signal convention" do
      rule = %{"signal" => "vix_last", "op" => "lt", "value" => 18}

      assert RuleEngine.margin(rule, %{"vix_last" => nil}) == 0.0
      assert RuleEngine.margin_or_nil(rule, %{"vix_last" => nil}) == 0.0
    end

    test "a transition op with a nil current or prior value fails closed" do
      rule = %{"signal" => "deriv", "op" => "sign_flip"}

      refute RuleEngine.evaluate(rule, %{"deriv" => nil, "prev_deriv" => 0.5})
      refute RuleEngine.evaluate(rule, %{"deriv" => -0.5, "prev_deriv" => nil})
    end

    test "a nil leg does not poison an any combinator's other legs" do
      rule = %{
        "any" => [
          %{"signal" => "vix_last", "op" => "gt", "value" => 0},
          %{"signal" => "spy_return_5m", "op" => "gt", "value" => 0}
        ]
      }

      # The nil leg declines; the live leg still carries the rule.
      assert RuleEngine.evaluate(rule, %{"vix_last" => nil, "spy_return_5m" => 1.5})
    end

    test "a nil leg makes an all combinator false without raising" do
      rule = %{
        "all" => [
          %{"signal" => "vix_last", "op" => "gt", "value" => 0},
          %{"signal" => "spy_return_5m", "op" => "gt", "value" => 0}
        ]
      }

      refute RuleEngine.evaluate(rule, %{"vix_last" => nil, "spy_return_5m" => 1.5})
    end
  end

  describe "margin/2 — combinators" do
    test "all averages its children's margins" do
      rule = %{
        "all" => [
          %{"signal" => "spy_return_5m", "op" => "gt", "value" => 0},
          %{"signal" => "vix_last", "op" => "lt", "value" => 18}
        ]
      }

      snapshot = %{"spy_return_5m" => 1.0, "vix_last" => 9}

      leg_a =
        RuleEngine.margin(%{"signal" => "spy_return_5m", "op" => "gt", "value" => 0}, snapshot)

      leg_b = RuleEngine.margin(%{"signal" => "vix_last", "op" => "lt", "value" => 18}, snapshot)

      assert_in_delta RuleEngine.margin(rule, snapshot), (leg_a + leg_b) / 2, 0.0001
    end

    test "any takes the max of its children's margins" do
      rule = %{
        "any" => [
          %{"signal" => "vix_last", "op" => "lt", "value" => 18},
          %{"signal" => "regime", "op" => "eq", "value" => 1}
        ]
      }

      snapshot = %{"vix_last" => 9, "regime" => 2}
      leg_a = RuleEngine.margin(%{"signal" => "vix_last", "op" => "lt", "value" => 18}, snapshot)

      assert RuleEngine.margin(rule, snapshot) == leg_a
    end

    test "not inverts the margin" do
      rule = %{"not" => %{"signal" => "vix_last", "op" => "lt", "value" => 18}}

      inner =
        RuleEngine.margin(%{"signal" => "vix_last", "op" => "lt", "value" => 18}, %{
          "vix_last" => 22
        })

      assert_in_delta RuleEngine.margin(rule, %{"vix_last" => 22}), 1.0 - inner, 0.0001
    end
  end

  describe "signal_names/1" do
    test "nil rule has no signal names" do
      assert RuleEngine.signal_names(nil) == []
    end

    test "empty map rule has no signal names" do
      assert RuleEngine.signal_names(%{}) == []
    end

    test "a single leaf condition yields its signal name" do
      rule = %{"signal" => "vix_last", "op" => "lt", "value" => 18}
      assert RuleEngine.signal_names(rule) == ["vix_last"]
    end

    test "a value_signal comparand is included alongside the leaf signal" do
      rule = %{
        "signal" => "current_price",
        "op" => "lte",
        "value_signal" => "run_stop_loss_price"
      }

      assert RuleEngine.signal_names(rule) == ["current_price", "run_stop_loss_price"]
    end

    test "collects names across all/any/not combinators" do
      rule = %{
        "all" => [
          %{"signal" => "momentum:SPY:5m", "op" => "gt", "value" => 0},
          %{"not" => %{"signal" => "vix_last", "op" => "gt", "value" => 30}},
          %{
            "any" => [
              %{
                "signal" => "current_price",
                "op" => "lte",
                "value_signal" => "run_stop_loss_price"
              }
            ]
          }
        ]
      }

      assert Enum.sort(RuleEngine.signal_names(rule)) ==
               Enum.sort([
                 "momentum:SPY:5m",
                 "vix_last",
                 "current_price",
                 "run_stop_loss_price"
               ])
    end

    test "a malformed shape yields no signal names" do
      assert RuleEngine.signal_names(%{"unrecognized" => "shape"}) == []
    end
  end

  describe "regime_condition?/1" do
    test "true when regime_trend_ordinal is nested inside an all combinator" do
      rule = %{
        "all" => [
          %{"signal" => "vix_last", "op" => "lt", "value" => 18},
          %{"signal" => "regime_trend_ordinal", "op" => "gte", "value" => 0}
        ]
      }

      assert RuleEngine.regime_condition?(rule)
    end

    test "true when regime_vol_ordinal is nested inside an any inside a not" do
      rule = %{
        "not" => %{
          "any" => [
            %{"signal" => "regime_vol_ordinal", "op" => "lt", "value" => 0}
          ]
        }
      }

      assert RuleEngine.regime_condition?(rule)
    end

    test "false for a rule tree referencing neither regime pseudo-signal" do
      rule = %{
        "all" => [
          %{"signal" => "momentum:SPY:5m", "op" => "gt", "value" => 0},
          %{
            "signal" => "current_price",
            "op" => "lte",
            "value_signal" => "run_stop_loss_price"
          }
        ]
      }

      refute RuleEngine.regime_condition?(rule)
    end

    test "false for nil rules" do
      refute RuleEngine.regime_condition?(nil)
    end
  end

  describe "transition operators: crosses_above" do
    @crosses_above %{"signal" => "deriv", "op" => "crosses_above", "value" => 0}

    test "fires when prev is at or below the threshold and now is above it" do
      assert RuleEngine.evaluate(@crosses_above, %{"deriv" => 0.5, "prev_deriv" => -0.5})
    end

    test "fires from exactly the threshold (prev == T counts as below)" do
      assert RuleEngine.evaluate(@crosses_above, %{"deriv" => 0.5, "prev_deriv" => 0})
    end

    test "does not fire when already above on both ticks -- this is the whipsaw case" do
      refute RuleEngine.evaluate(@crosses_above, %{"deriv" => 0.9, "prev_deriv" => 0.5})
    end

    test "does not fire when crossing the other way" do
      refute RuleEngine.evaluate(@crosses_above, %{"deriv" => -0.5, "prev_deriv" => 0.5})
    end

    test "does not fire when now lands exactly on the threshold" do
      refute RuleEngine.evaluate(@crosses_above, %{"deriv" => 0, "prev_deriv" => -0.5})
    end

    test "works against a value_signal comparand, not just a literal" do
      rule = %{"signal" => "price", "op" => "crosses_above", "value_signal" => "run_stop"}

      assert RuleEngine.evaluate(rule, %{"price" => 11, "prev_price" => 9, "run_stop" => 10})
      refute RuleEngine.evaluate(rule, %{"price" => 12, "prev_price" => 11, "run_stop" => 10})
    end
  end

  describe "transition operators: crosses_below" do
    @crosses_below %{"signal" => "deriv", "op" => "crosses_below", "value" => 0}

    test "fires when prev is at or above the threshold and now is below it" do
      assert RuleEngine.evaluate(@crosses_below, %{"deriv" => -0.5, "prev_deriv" => 0.5})
    end

    test "fires from exactly the threshold (prev == T counts as above)" do
      assert RuleEngine.evaluate(@crosses_below, %{"deriv" => -0.5, "prev_deriv" => 0})
    end

    test "does not fire when already below on both ticks" do
      refute RuleEngine.evaluate(@crosses_below, %{"deriv" => -0.9, "prev_deriv" => -0.5})
    end

    test "does not fire when crossing the other way" do
      refute RuleEngine.evaluate(@crosses_below, %{"deriv" => 0.5, "prev_deriv" => -0.5})
    end
  end

  describe "transition operators: sign_flip" do
    @sign_flip %{"signal" => "deriv", "op" => "sign_flip"}

    test "fires on positive to negative" do
      assert RuleEngine.evaluate(@sign_flip, %{"deriv" => -0.2, "prev_deriv" => 0.3})
    end

    test "fires on negative to positive" do
      assert RuleEngine.evaluate(@sign_flip, %{"deriv" => 0.3, "prev_deriv" => -0.2})
    end

    test "does not fire when the sign is unchanged, however large the move" do
      refute RuleEngine.evaluate(@sign_flip, %{"deriv" => 99.0, "prev_deriv" => 0.001})
      refute RuleEngine.evaluate(@sign_flip, %{"deriv" => -99.0, "prev_deriv" => -0.001})
    end

    # Documented decision: zero is "no sign", not its own sign. A signal
    # resting at 0.0 must not emit a flip every tick it wobbles across --
    # that is exactly the churn these operators exist to suppress.
    test "does not fire moving off zero (zero is no-sign, not a sign)" do
      refute RuleEngine.evaluate(@sign_flip, %{"deriv" => 0.5, "prev_deriv" => 0})
      refute RuleEngine.evaluate(@sign_flip, %{"deriv" => -0.5, "prev_deriv" => 0})
    end

    test "does not fire moving onto zero" do
      refute RuleEngine.evaluate(@sign_flip, %{"deriv" => 0, "prev_deriv" => 0.5})
      refute RuleEngine.evaluate(@sign_flip, %{"deriv" => 0, "prev_deriv" => -0.5})
    end

    test "+ -> 0 -> - is a single flip, observed on the 0 -> - step" do
      refute RuleEngine.evaluate(@sign_flip, %{"deriv" => 0, "prev_deriv" => 0.5})
      refute RuleEngine.evaluate(@sign_flip, %{"deriv" => -0.5, "prev_deriv" => 0})
      # ...and the direct + -> - step, had zero not intervened, is the one flip.
      assert RuleEngine.evaluate(@sign_flip, %{"deriv" => -0.5, "prev_deriv" => 0.5})
    end

    test "does not fire when both sides are zero" do
      refute RuleEngine.evaluate(@sign_flip, %{"deriv" => 0, "prev_deriv" => 0})
    end
  end

  describe "transition operators: changed" do
    @changed %{"signal" => "state", "op" => "changed"}

    test "fires on any different value" do
      assert RuleEngine.evaluate(@changed, %{"state" => 1, "prev_state" => 0})
      assert RuleEngine.evaluate(@changed, %{"state" => -1, "prev_state" => 1})
    end

    test "fires moving off zero, unlike sign_flip" do
      assert RuleEngine.evaluate(@changed, %{"state" => 0.5, "prev_state" => 0})
    end

    test "does not fire on an identical value" do
      refute RuleEngine.evaluate(@changed, %{"state" => 1, "prev_state" => 1})
    end

    test "compares numerically, so 1 and 1.0 are not a change" do
      refute RuleEngine.evaluate(@changed, %{"state" => 1.0, "prev_state" => 1})
    end
  end

  describe "transition operators: missing prev_ fails closed" do
    # This is what makes the first evaluation after entry safe: with no
    # prior value seeded, no transition fires on tick one, so a position
    # that opens already past T does not instantly exit.
    test "crosses_above does not fire without a prev_ key" do
      refute RuleEngine.evaluate(@crosses_above, %{"deriv" => 0.5})
    end

    test "crosses_below does not fire without a prev_ key" do
      refute RuleEngine.evaluate(@crosses_below, %{"deriv" => -0.5})
    end

    test "sign_flip does not fire without a prev_ key" do
      refute RuleEngine.evaluate(@sign_flip, %{"deriv" => -0.5})
    end

    test "changed does not fire without a prev_ key" do
      refute RuleEngine.evaluate(@changed, %{"state" => 1})
    end

    test "does not fire when the current value is missing either" do
      refute RuleEngine.evaluate(@sign_flip, %{"prev_deriv" => 0.5})
    end

    test "a thresholded transition does not fire when its value_signal is missing" do
      rule = %{"signal" => "price", "op" => "crosses_above", "value_signal" => "run_stop"}

      refute RuleEngine.evaluate(rule, %{"price" => 11, "prev_price" => 9})
    end
  end

  describe "transition operators: signal_names/1 excludes prev_ keys" do
    test "a transition condition yields only the bare signal name" do
      assert RuleEngine.signal_names(@sign_flip) == ["deriv"]
      assert RuleEngine.signal_names(@crosses_above) == ["deriv"]
    end

    test "a thresholded transition yields the bare name and its value_signal, no prev_" do
      rule = %{"signal" => "price", "op" => "crosses_above", "value_signal" => "run_stop"}

      assert RuleEngine.signal_names(rule) == ["price", "run_stop"]
    end

    test "no prev_ name leaks out of a nested tree" do
      rule = %{
        "all" => [
          %{"signal" => "deriv", "op" => "sign_flip"},
          %{"not" => %{"signal" => "vix_last", "op" => "crosses_below", "value" => 18}}
        ]
      }

      names = RuleEngine.signal_names(rule)

      assert Enum.sort(names) == ["deriv", "vix_last"]
      refute Enum.any?(names, &String.starts_with?(&1, "prev_"))
    end
  end

  describe "margin_or_nil/2: a transition leg has no margin" do
    # A transition fired or it didn't -- there is no "how far past the
    # threshold" reading. Scoring it 1.0/0.0 would smuggle a boolean into
    # a continuous statistic; averaged across runs that is a fire rate
    # wearing the name "mean margin".
    test "a bare transition leg is nil whether or not it fired" do
      assert RuleEngine.margin_or_nil(@sign_flip, %{"deriv" => -0.2, "prev_deriv" => 0.3}) == nil
      assert RuleEngine.margin_or_nil(@sign_flip, %{"deriv" => 0.2, "prev_deriv" => 0.3}) == nil
    end

    test "nil for every transition op, independent of the boolean evaluate/2 gives" do
      snapshot = %{"deriv" => -0.5, "prev_deriv" => 0.5}

      for op <- ["crosses_above", "crosses_below", "sign_flip", "changed"] do
        condition = %{"signal" => "deriv", "op" => op, "value" => 0}

        assert RuleEngine.margin_or_nil(condition, snapshot) == nil
      end
    end

    test "nil on a missing prev_ too -- absence is about the operator, not the data" do
      assert RuleEngine.margin_or_nil(@sign_flip, %{"deriv" => -0.2}) == nil
    end

    test "evaluate/2 is unaffected -- an absent margin is still a decisive gate" do
      assert RuleEngine.evaluate(@sign_flip, %{"deriv" => -0.2, "prev_deriv" => 0.3})
      refute RuleEngine.evaluate(@sign_flip, %{"deriv" => 0.2, "prev_deriv" => 0.3})
    end
  end

  describe "margin_or_nil/2: absence propagates through combinators" do
    @threshold %{"signal" => "vix_last", "op" => "lt", "value" => 20}

    test "all averages only the legs that have a margin" do
      snapshot = %{"vix_last" => 10, "deriv" => -0.5, "prev_deriv" => 0.5}
      rule = %{"all" => [@threshold, @sign_flip]}

      # The transition leg is in neither the numerator nor the
      # denominator, so this scores exactly what the lone threshold leg
      # scored -- not an average of it with a 1.0.
      threshold_only = RuleEngine.margin_or_nil(@threshold, snapshot)

      assert RuleEngine.margin_or_nil(rule, snapshot) == threshold_only
      assert threshold_only != 1.0
    end

    test "all with two threshold legs and a transition averages just the two" do
      snapshot = %{
        "vix_last" => 10,
        "spy_return_5m" => 0.5,
        "deriv" => -0.5,
        "prev_deriv" => 0.5
      }

      other = %{"signal" => "spy_return_5m", "op" => "gt", "value" => 0}
      rule = %{"all" => [@threshold, @sign_flip, other]}

      a = RuleEngine.margin_or_nil(@threshold, snapshot)
      b = RuleEngine.margin_or_nil(other, snapshot)

      assert_in_delta RuleEngine.margin_or_nil(rule, snapshot), (a + b) / 2, 0.0001
    end

    test "any takes the max over the legs that have a margin" do
      snapshot = %{"vix_last" => 10, "deriv" => -0.5, "prev_deriv" => 0.5}
      rule = %{"any" => [@threshold, @sign_flip]}

      # A fired transition must not win the max with a 1.0.
      assert RuleEngine.margin_or_nil(rule, snapshot) ==
               RuleEngine.margin_or_nil(@threshold, snapshot)
    end

    test "an all-transition rule has no margin at all" do
      snapshot = %{"deriv" => -0.5, "prev_deriv" => 0.5, "x" => 1, "prev_x" => 0}
      rule = %{"all" => [@sign_flip, %{"signal" => "x", "op" => "changed"}]}

      assert RuleEngine.margin_or_nil(rule, snapshot) == nil
    end

    test "an any-of-all-transitions rule has no margin either" do
      snapshot = %{"deriv" => -0.5, "prev_deriv" => 0.5, "x" => 1, "prev_x" => 0}
      rule = %{"any" => [@sign_flip, %{"signal" => "x", "op" => "changed"}]}

      assert RuleEngine.margin_or_nil(rule, snapshot) == nil
    end

    test "not over a transition leg propagates absence rather than inverting it" do
      snapshot = %{"deriv" => -0.5, "prev_deriv" => 0.5}

      assert RuleEngine.margin_or_nil(%{"not" => @sign_flip}, snapshot) == nil
    end

    test "not over a threshold leg still inverts as before" do
      snapshot = %{"vix_last" => 10}
      inner = RuleEngine.margin_or_nil(@threshold, snapshot)

      assert RuleEngine.margin_or_nil(%{"not" => @threshold}, snapshot) == 1.0 - inner
    end

    test "absence propagates up through nesting" do
      snapshot = %{"deriv" => -0.5, "prev_deriv" => 0.5}
      rule = %{"all" => [%{"any" => [%{"not" => @sign_flip}]}]}

      assert RuleEngine.margin_or_nil(rule, snapshot) == nil
    end
  end

  describe "margin/2 keeps a float contract for callers that store a confidence" do
    test "an all-transition rule reports 1.0, matching how a nil/empty rule is treated" do
      snapshot = %{"deriv" => -0.5, "prev_deriv" => 0.5}

      assert RuleEngine.margin_or_nil(@sign_flip, snapshot) == nil
      assert RuleEngine.margin(@sign_flip, snapshot) == 1.0
      # ...the same answer margin/2 already gives for "nothing constrains this".
      assert RuleEngine.margin(nil, snapshot) == 1.0
      assert RuleEngine.margin(%{}, snapshot) == 1.0
    end

    test "a mixed rule reports the measurable legs' score as a plain float" do
      snapshot = %{"vix_last" => 10, "deriv" => -0.5, "prev_deriv" => 0.5}
      rule = %{"all" => [@threshold, @sign_flip]}

      result = RuleEngine.margin(rule, snapshot)

      assert is_float(result)
      assert result == RuleEngine.margin_or_nil(@threshold, snapshot)
    end

    test "threshold-only rules are bit-identical to margin_or_nil" do
      snapshot = %{"vix_last" => 10, "spy_return_5m" => 0.5}

      rules = [
        @threshold,
        %{"signal" => "spy_return_5m", "op" => "gt", "value" => 0},
        %{"all" => [@threshold, %{"signal" => "spy_return_5m", "op" => "gt", "value" => 0}]},
        %{"any" => [@threshold, %{"signal" => "spy_return_5m", "op" => "gt", "value" => 0}]},
        %{"not" => @threshold}
      ]

      for rule <- rules do
        assert RuleEngine.margin(rule, snapshot) == RuleEngine.margin_or_nil(rule, snapshot)
      end
    end

    test "fail-closed scoring is unchanged: a missing signal still scores 0.0, not nil" do
      # Absence is reserved for "this operator has no margin", NOT for
      # "the data was missing" -- that must stay a hard 0.0 so a rule
      # referencing an unsupplied signal can never be averaged away as
      # though it were unmeasurable.
      assert RuleEngine.margin_or_nil(@threshold, %{}) == 0.0
      assert RuleEngine.margin(@threshold, %{}) == 0.0
      assert RuleEngine.margin_or_nil(%{"nonsense" => true}, %{}) == 0.0
    end
  end

  describe "transition operators: existing operators are unaffected" do
    # The compatibility requirement: a version only gets new behavior if
    # its rule JSON opts into a new operator. prev_ keys sitting unused in
    # the snapshot must change nothing, so trading_system can A/B retired
    # versions against their own history with identical signals and
    # thresholds, changing only trigger semantics.
    test "a gt rule behaves identically with and without prev_ keys present" do
      rule = %{"signal" => "vix_last", "op" => "gt", "value" => 18}
      without = %{"vix_last" => 20}
      with_prev = %{"vix_last" => 20, "prev_vix_last" => 5}

      assert RuleEngine.evaluate(rule, without) == RuleEngine.evaluate(rule, with_prev)
      assert RuleEngine.margin(rule, without) == RuleEngine.margin(rule, with_prev)
    end

    test "every stateless operator ignores a contradicting prev_ value" do
      snapshot = %{"x" => 10, "prev_x" => 10_000}

      for {op, expected} <- [
            {"gt", true},
            {"gte", true},
            {"lt", false},
            {"lte", false},
            {"eq", false}
          ] do
        condition = %{"signal" => "x", "op" => op, "value" => 5}

        assert RuleEngine.evaluate(condition, snapshot) == expected,
               "#{op} changed behavior when an unused prev_ key was present"
      end
    end

    test "signal_names/1 shape is unchanged for a stateless rule" do
      rule = %{
        "signal" => "current_price",
        "op" => "lte",
        "value_signal" => "run_stop_loss_price"
      }

      assert RuleEngine.signal_names(rule) == ["current_price", "run_stop_loss_price"]
    end

    test "regime_condition?/1 still works and ignores transition ops" do
      rule = %{
        "all" => [
          %{"signal" => "regime_vol_ordinal", "op" => "crosses_above", "value" => 0},
          %{"signal" => "deriv", "op" => "sign_flip"}
        ]
      }

      assert RuleEngine.regime_condition?(rule)
      refute RuleEngine.regime_condition?(%{"signal" => "deriv", "op" => "sign_flip"})
    end
  end

  describe "transition operators: combinators" do
    test "composes inside all/any/not like any other condition" do
      snapshot = %{"deriv" => -0.5, "prev_deriv" => 0.5, "vix_last" => 20}

      assert RuleEngine.evaluate(
               %{
                 "all" => [
                   %{"signal" => "deriv", "op" => "sign_flip"},
                   %{"signal" => "vix_last", "op" => "gt", "value" => 18}
                 ]
               },
               snapshot
             )

      refute RuleEngine.evaluate(
               %{"not" => %{"signal" => "deriv", "op" => "sign_flip"}},
               snapshot
             )
    end
  end
end
