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
end
