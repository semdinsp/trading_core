defmodule TradingCore.Regime.PlaybookTest.Rules do
  @moduledoc false

  def rule(id, attrs) do
    Map.merge(
      %{
        id: id,
        vol_state: :any,
        trend_state: :any,
        selector: :all,
        action: :allow,
        size_multiplier: Decimal.new(1),
        priority: 0,
        enabled: true
      },
      Map.new(attrs)
    )
  end

  def rule(id), do: rule(id, [])

  def block(id, attrs \\ []),
    do: rule(id, Keyword.merge([action: :block, size_multiplier: nil], attrs))
end

defmodule TradingCore.Regime.PlaybookTest do
  use ExUnit.Case, async: true

  alias TradingCore.Regime.Playbook

  import TradingCore.Regime.PlaybookTest.Rules

  @ctx %{strategy_id: "strat-1", tags: ["tick", "semis"], exposure: :long_market}
  @half Decimal.new("0.5")

  describe "evaluate/4 — specificity ladder" do
    # Each case: rules, label, expected decision. The winning rule is
    # always the more specific one, whichever order the rules are listed in.
    cases = [
      {"strategy_id beats tag",
       [block("a", selector: {:tag, "tick"}), rule("b", selector: {:strategy_id, "strat-1"})],
       {:allow, "b"}},
      {"tag beats exposure",
       [block("a", selector: {:exposure, :long_market}), rule("b", selector: {:tag, "semis"})],
       {:allow, "b"}},
      {"exposure beats all",
       [block("a", selector: :all), rule("b", selector: {:exposure, :long_market})],
       {:allow, "b"}},
      {"selector dominates label specificity",
       [
         block("a", selector: :all, vol_state: :stressed, trend_state: :chop),
         rule("b", selector: {:tag, "tick"})
       ], {:allow, "b"}},
      {"both exact beats one exact",
       [rule("a", vol_state: :stressed), block("b", vol_state: :stressed, trend_state: :chop)],
       {:block, "b"}},
      {"one exact beats any/any", [rule("a"), block("b", trend_state: :chop)], {:block, "b"}},
      {"priority breaks label ties", [rule("a", priority: 1), block("b", priority: 5)],
       {:block, "b"}},
      {"rule id breaks full ties", [block("z"), rule("a")], {:allow, "a"}},
      {"disabled rule is ignored",
       [rule("a"), block("b", selector: {:strategy_id, "strat-1"}, enabled: false)],
       {:allow, "a"}},
      {"non-matching tag is ignored", [rule("a"), block("b", selector: {:tag, "other"})],
       {:allow, "a"}},
      {"non-matching exposure is ignored",
       [rule("a"), block("b", selector: {:exposure, :short_market})], {:allow, "a"}},
      {"non-matching cell is ignored", [rule("a"), block("b", vol_state: :calm)], {:allow, "a"}}
    ]

    for {name, rules, expected} <- cases do
      @rules rules
      @expected expected
      test name do
        for rules <- [@rules, Enum.reverse(@rules)] do
          result = Playbook.evaluate(rules, @ctx, "stressed|chop")

          case @expected do
            {:allow, id} -> assert {:allow, _, ^id} = result
            {:block, id} -> assert {:block, ^id} = result
          end
        end
      end
    end

    test "allow returns the winning rule's multiplier, never a product" do
      rules = [
        rule("a", size_multiplier: @half),
        rule("b", selector: {:tag, "tick"}, size_multiplier: Decimal.new("0.25"))
      ]

      assert {:allow, m, "b"} = Playbook.evaluate(rules, @ctx, "calm|up")
      assert Decimal.equal?(m, Decimal.new("0.25"))
    end
  end

  describe "evaluate/4 — fallbacks" do
    test "no matching rule uses :default (allow ×1 when not given)" do
      assert {:allow, m, :default} = Playbook.evaluate([], @ctx, "calm|up")
      assert Decimal.equal?(m, 1)
      assert {:block, :default} = Playbook.evaluate([], @ctx, "calm|up", default: :block)
    end

    test "only disabled rules ⇒ :default" do
      assert {:block, :default} =
               Playbook.evaluate([rule("a", enabled: false)], @ctx, "calm|up", default: :block)
    end

    test "nil label uses :nil_regime (block when not given)" do
      assert {:block, :nil_regime} = Playbook.evaluate([rule("a")], @ctx, nil)
    end

    test "unparseable labels use :nil_regime and never raise" do
      for label <- ["garbage", "", "Calm|Up", "calm|up|x", "calm", :calm_up, 42] do
        assert {:allow, m, :nil_regime} =
                 Playbook.evaluate([rule("a")], @ctx, label, nil_regime: {:allow, @half})

        assert Decimal.equal?(m, @half)
      end
    end
  end

  describe "grid/3" do
    test "returns all nine cells" do
      rules = [block("a", vol_state: :stressed)]
      grid = Playbook.grid(rules, @ctx)

      assert map_size(grid) == 9

      for vol <- [:calm, :normal, :stressed], trend <- [:up, :chop, :down] do
        expected =
          if vol == :stressed, do: {:block, "a"}, else: {:allow, Decimal.new(1), :default}

        assert grid[{vol, trend}] == expected
      end
    end
  end

  describe "validate_rule/1" do
    test "normalizes a valid allow rule with defaults" do
      assert {:ok, rule} =
               Playbook.validate_rule(%{
                 id: "r1",
                 vol_state: :stressed,
                 trend_state: :any,
                 selector: {:tag, "tick"},
                 action: :allow,
                 size_multiplier: "0.5"
               })

      assert rule.priority == 0
      assert rule.enabled == true
      assert Decimal.equal?(rule.size_multiplier, @half)
    end

    test "accepts the [0, 1] boundaries" do
      for m <- [Decimal.new(0), Decimal.new(1)] do
        assert {:ok, _} = Playbook.validate_rule(rule("r", size_multiplier: m))
      end
    end

    test "rejects multipliers outside [0, 1] and floats" do
      assert {:error, [:size_multiplier_out_of_range]} =
               Playbook.validate_rule(rule("r", size_multiplier: Decimal.new("1.01")))

      assert {:error, [:size_multiplier_out_of_range]} =
               Playbook.validate_rule(rule("r", size_multiplier: Decimal.new("-0.1")))

      assert {:error, [:invalid_size_multiplier]} =
               Playbook.validate_rule(rule("r", size_multiplier: 0.5))

      assert {:error, [:invalid_size_multiplier]} =
               Playbook.validate_rule(rule("r", size_multiplier: nil))
    end

    test "block ignores size_multiplier" do
      assert {:ok, %{size_multiplier: nil}} =
               Playbook.validate_rule(block("r", size_multiplier: Decimal.new(7)))
    end

    test "collects every structural error" do
      assert {:error, errors} =
               Playbook.validate_rule(%{
                 id: "",
                 vol_state: :hot,
                 trend_state: :sideways,
                 selector: {:exposure, :flat},
                 action: :maybe,
                 priority: "high",
                 enabled: "yes"
               })

      assert Enum.sort(errors) ==
               Enum.sort([
                 :invalid_id,
                 :invalid_vol_state,
                 :invalid_trend_state,
                 :invalid_selector,
                 :invalid_action,
                 :invalid_priority,
                 :invalid_enabled
               ])
    end
  end
end
