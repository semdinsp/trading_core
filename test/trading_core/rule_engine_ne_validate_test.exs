defmodule TradingCore.RuleEngineNeValidateTest do
  use ExUnit.Case, async: true

  alias TradingCore.RuleEngine

  # trading_system's real shape: exit when the regime is no longer bearish.
  @ne %{"op" => "ne", "signal" => "ibkr_regime_tick_vix", "value" => -1}

  describe "ne" do
    test "true when different, false when equal" do
      assert RuleEngine.evaluate(@ne, %{"ibkr_regime_tick_vix" => 0})
      assert RuleEngine.evaluate(@ne, %{"ibkr_regime_tick_vix" => 1})
      refute RuleEngine.evaluate(@ne, %{"ibkr_regime_tick_vix" => -1})
      refute RuleEngine.evaluate(@ne, %{"ibkr_regime_tick_vix" => Decimal.new("-1.00")})
    end

    test "missing or nil data is unknown: it never passes, even negated" do
      for snapshot <- [%{}, %{"ibkr_regime_tick_vix" => nil}] do
        refute RuleEngine.evaluate(@ne, snapshot)
        refute RuleEngine.evaluate(%{"not" => @ne}, snapshot)
      end
    end

    test "inside not / all / any" do
      snapshot = %{"ibkr_regime_tick_vix" => -1, "vix" => 30}
      vix_high = %{"signal" => "vix", "op" => "gt", "value" => 20}

      assert RuleEngine.evaluate(%{"not" => @ne}, snapshot)
      refute RuleEngine.evaluate(%{"all" => [@ne, vix_high]}, snapshot)
      assert RuleEngine.evaluate(%{"any" => [@ne, vix_high]}, snapshot)

      assert RuleEngine.evaluate(%{"all" => [@ne, vix_high]}, %{
               snapshot
               | "ibkr_regime_tick_vix" => 0
             })
    end

    test "with a value_signal comparand" do
      rule = %{"signal" => "a", "op" => "ne", "value_signal" => "b"}
      assert RuleEngine.evaluate(rule, %{"a" => 1, "b" => 2})
      refute RuleEngine.evaluate(rule, %{"a" => 2, "b" => 2})
      refute RuleEngine.evaluate(rule, %{"a" => 2})
    end

    test "margin is pass/fail like eq" do
      assert RuleEngine.margin(@ne, %{"ibkr_regime_tick_vix" => 0}) == 1.0
      assert RuleEngine.margin(@ne, %{"ibkr_regime_tick_vix" => -1}) == 0.0
    end
  end

  describe "operator lists" do
    test "comparison, transition and known ops" do
      assert RuleEngine.comparison_ops() == ~w(gt gte lt lte eq ne)
      assert RuleEngine.transition_ops() == ~w(crosses_above crosses_below sign_flip changed)
      assert RuleEngine.known_ops() == RuleEngine.comparison_ops() ++ RuleEngine.transition_ops()
    end
  end

  describe "validate/2 accepts everything evaluate/2 evaluates" do
    test "every supported op, with each comparand form" do
      for op <- RuleEngine.comparison_ops() ++ ["crosses_above", "crosses_below"],
          comparand <- [
            %{"value" => 5},
            %{"value" => "5.25"},
            %{"value" => -1.5},
            %{"value_signal" => "b"}
          ] do
        assert RuleEngine.validate(Map.merge(%{"signal" => "a", "op" => op}, comparand)) == :ok,
               "#{op} #{inspect(comparand)}"
      end

      assert RuleEngine.validate(%{"signal" => "a", "op" => "sign_flip"}) == :ok
      assert RuleEngine.validate(%{"signal" => "a", "op" => "changed"}) == :ok
    end

    test "nil and %{} at any depth, all [], and nested combinators" do
      leaf = %{"signal" => "a", "op" => "gt", "value" => 1}

      for rule <- [
            nil,
            %{},
            %{"all" => []},
            %{"all" => [nil, %{}, leaf]},
            %{"any" => [leaf, %{"not" => %{"all" => [leaf, %{}]}}]},
            %{"not" => leaf}
          ] do
        assert RuleEngine.validate(rule) == :ok, inspect(rule)
      end
    end

    test "does not fire on a healthy realistic rule set" do
      rules = %{
        "entry" => %{
          "all" => [
            %{"signal" => "massive_spy_derivative", "op" => "gt", "value" => 0},
            %{"signal" => "regime_vol_ordinal", "op" => "lte", "value" => "0"},
            %{"any" => [%{"signal" => "vix", "op" => "lt", "value" => 25}, %{}]}
          ]
        },
        "exit" => %{
          "any" => [
            %{
              "signal" => "run_current_price",
              "op" => "lte",
              "value_signal" => "run_stop_loss_price"
            },
            @ne,
            %{"signal" => "wavelet", "op" => "crosses_below", "value" => 0}
          ]
        }
      }

      assert RuleEngine.validate_rules(rules) == :ok
      assert RuleEngine.validate_rules(%{"entry" => nil}) == :ok
    end
  end

  describe "validate/2 rejects" do
    test "unknown ops, with their path" do
      for op <- ["neq", "!=", "NE", "between"] do
        assert {:error, [{["op"], :unknown_op}]} =
                 RuleEngine.validate(%{"signal" => "a", "op" => op, "value" => 1})
      end

      rule = %{
        "all" => [
          %{"signal" => "a", "op" => "gt", "value" => 1},
          %{"not" => %{"signal" => "b", "op" => "neq", "value" => 2}}
        ]
      }

      assert RuleEngine.validate(rule) == {:error, [{["all", 1, "not", "op"], :unknown_op}]}
    end

    test "missing signal, op and comparand" do
      assert {:error, errors} = RuleEngine.validate(%{"op" => "gt"})
      assert {["signal"], :missing_signal} in errors
      assert {["value"], :missing_value} in errors

      assert RuleEngine.validate(%{"signal" => "a", "value" => 1}) ==
               {:error, [{["op"], :missing_op}]}

      assert RuleEngine.validate(%{"signal" => "a", "op" => "eq", "value" => nil}) ==
               {:error, [{["value"], :missing_value}]}

      assert RuleEngine.validate(%{"signal" => "a", "op" => "crosses_above"}) ==
               {:error, [{["value"], :missing_value}]}
    end

    test "non-numeric values and bad value_signals" do
      for bad <- ["abc", "1.2.3", "", true, [], %{}] do
        assert RuleEngine.validate(%{"signal" => "a", "op" => "gt", "value" => bad}) ==
                 {:error, [{["value"], :non_numeric_value}]},
               inspect(bad)
      end

      assert RuleEngine.validate(%{"signal" => "a", "op" => "gt", "value_signal" => 3}) ==
               {:error, [{["value_signal"], :invalid_value_signal}]}
    end

    test "bad shapes: any [], non-list all/any, non-map not, unknown nodes" do
      assert RuleEngine.validate(%{"any" => []}) == {:error, [{["any"], :empty_any}]}
      assert RuleEngine.validate(%{"all" => "x"}) == {:error, [{["all"], :invalid_conditions}]}
      assert RuleEngine.validate(%{"not" => [1]}) == {:error, [{["not"], :invalid_not}]}
      assert RuleEngine.validate(%{"if" => 1}) == {:error, [{[], :malformed_node}]}
      assert RuleEngine.validate(%{"all" => [42]}) == {:error, [{["all", 0], :malformed_node}]}
    end

    test "transition ops where the caller supplies no prev_ values" do
      crosses = %{"signal" => "a", "op" => "crosses_above", "value" => 0}
      refuse = [allow_transition_ops: false]

      assert RuleEngine.validate(crosses) == :ok

      assert RuleEngine.validate(%{"all" => [crosses]}, refuse) ==
               {:error, [{["all", 0, "op"], :transition_op_not_allowed}]}

      assert RuleEngine.validate(%{"signal" => "a", "op" => "gt", "value" => 0}, refuse) == :ok

      # entry rejects transitions, exit allows them
      assert RuleEngine.validate_rules(%{"entry" => crosses, "exit" => crosses}, entry: refuse) ==
               {:error, [{["entry", "op"], :transition_op_not_allowed}]}
    end
  end

  test "format_errors/1 names each path" do
    rules = %{
      "entry" => %{
        "all" => [
          %{"signal" => "a", "op" => "gt", "value" => 1},
          %{"not" => %{"signal" => "b", "op" => "neq", "value" => 2}}
        ]
      },
      "exit" => %{"any" => []}
    }

    assert [entry_msg, exit_msg] =
             rules |> RuleEngine.validate_rules() |> RuleEngine.format_errors()

    assert entry_msg =~
             ~r/^entry\.all\[1\]\.not\.op: unknown op \(supported: gt, gte, lt, lte, eq, ne, /

    assert exit_msg == "exit.any: an empty \"any\" can never pass"
    assert RuleEngine.format_errors(:ok) == []
  end

  test "evaluation of a non-numeric string value fails closed instead of raising" do
    rule = %{"signal" => "a", "op" => "gt", "value" => "abc"}
    refute RuleEngine.evaluate(rule, %{"a" => 5})
    refute RuleEngine.evaluate(%{"not" => rule}, %{"a" => 5})
    assert RuleEngine.evaluate(%{"signal" => "a", "op" => "gt", "value" => " 4.5 "}, %{"a" => 5})
  end
end
