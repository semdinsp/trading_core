defmodule TradingCore.UI.TokensTest do
  use ExUnit.Case, async: true

  alias TradingCore.UI.Tokens

  # These assertions ARE the contract. They are what makes a colour change
  # in one consuming app a failing build rather than a silent divergence
  # from the other — the same role TradingContract.Topics' tests play for
  # topic strings. Changing a string here should require changing it here
  # first, deliberately, not discovering later that two screens disagree.

  describe "lifecycle_stage/1" do
    test "discovery is a neutral outline" do
      assert Tokens.lifecycle_stage("discovery") ==
               "border-base-content/20 text-base-content/70"
    end

    test "quarantine is warning — amber is the workspace's needs-attention signal" do
      assert Tokens.lifecycle_stage("quarantine") ==
               "border-warning/40 text-warning bg-warning/10"
    end

    test "test_portfolio is primary — being trialled, neither a warning nor a success" do
      assert Tokens.lifecycle_stage("test_portfolio") ==
               "border-primary/40 text-primary bg-primary/10"
    end

    test "live is success — the most important stage must not be the least visible" do
      assert Tokens.lifecycle_stage("live") ==
               "border-success/40 text-success bg-success/10"
    end

    test "retired recedes further than discovery" do
      assert Tokens.lifecycle_stage("retired") ==
               "border-base-content/15 text-base-content/40"
    end

    test "quarantine and test_portfolio are distinct — they used to compete for amber" do
      refute Tokens.lifecycle_stage("quarantine") == Tokens.lifecycle_stage("test_portfolio")
    end

    test "every stage maps to a distinct string" do
      stages = ~w(discovery quarantine test_portfolio live retired)
      classes = Enum.map(stages, &Tokens.lifecycle_stage/1)

      assert length(Enum.uniq(classes)) == length(stages)
    end

    # Pins the no-fallback decision deliberately rather than by omission.
    # A catch-all returning a neutral outline is exactly how the two apps
    # drifted: each fell through for a different subset of stages, so
    # neither author saw a disagreement. A loud failure in test beats a
    # silently grey badge in production.
    test "an unknown stage raises rather than falling back to a neutral badge" do
      assert_raise FunctionClauseError, fn -> Tokens.lifecycle_stage("bogus") end
    end

    test "a stage typo raises rather than rendering something plausible" do
      assert_raise FunctionClauseError, fn -> Tokens.lifecycle_stage("quarantined") end
    end

    # Passed via a variable rather than a literal so the type checker
    # can't statically resolve the spec violation and warn — the point is
    # the runtime guard, which a caller reaching this from a database
    # column or a params map will hit with a real non-binary value.
    test "a non-binary stage raises" do
      for bad <- [:quarantine, nil, 1] do
        assert_raise FunctionClauseError, fn -> Tokens.lifecycle_stage(bad) end
      end
    end
  end

  describe "direction/1" do
    test "long uses the theme's own long colour, not success" do
      assert Tokens.direction("long") == "border-long/40 text-long bg-long/10"
    end

    test "short uses the theme's own short colour, not error" do
      assert Tokens.direction("short") == "border-short/40 text-short bg-short/10"
    end

    test "long and short are distinct" do
      refute Tokens.direction("long") == Tokens.direction("short")
    end

    test "an unknown direction raises rather than falling back" do
      assert_raise FunctionClauseError, fn -> Tokens.direction("sideways") end
    end

    test "a non-binary direction raises" do
      for bad <- [:long, nil] do
        assert_raise FunctionClauseError, fn -> Tokens.direction(bad) end
      end
    end
  end
end
