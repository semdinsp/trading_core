defmodule TradingCore.Signal.SpecTest do
  use ExUnit.Case, async: true

  alias TradingCore.Signal.Spec

  test "kinds/0 lists every recognized kind" do
    assert Enum.sort(Spec.kinds()) ==
             Enum.sort(~w(
               plain momentum derivative second_derivative wavelet volume vwap donchian
               rolling_volume self_zscore percent_deviation zscore regime ratio
             )a)
  end

  test "base_kind?/1, single_parent_kind?/1, dual_parent_kind?/1 partition the kind set" do
    for kind <- Spec.kinds() do
      flags = [
        Spec.base_kind?(kind),
        Spec.single_parent_kind?(kind),
        Spec.dual_parent_kind?(kind)
      ]

      assert Enum.count(flags, & &1) == 1, "#{kind} should belong to exactly one category"
    end

    assert Spec.base_kind?(:plain)
    assert Spec.single_parent_kind?(:derivative)
    assert Spec.dual_parent_kind?(:regime)
  end

  test "nodes/1 returns every node reachable via :parent/:reference, self included" do
    base = %Spec{kind: :plain}
    wavelet = %Spec{kind: :wavelet, parent: base}
    deriv = %Spec{kind: :derivative, parent: wavelet}

    nodes = Spec.nodes(deriv)

    assert deriv in nodes
    assert wavelet in nodes
    assert base in nodes
    assert length(nodes) == 3
  end

  test "nodes/1 walks both :parent and :reference for a dual-parent spec" do
    value = %Spec{kind: :plain}
    reference = %Spec{kind: :vwap}
    dev = %Spec{kind: :percent_deviation, parent: value, reference: reference}

    nodes = Spec.nodes(dev)

    assert dev in nodes
    assert value in nodes
    assert reference in nodes
    assert length(nodes) == 3
  end

  test "a spec is plain, comparable data" do
    a = %Spec{kind: :plain, symbol: "SPY"}
    b = %Spec{kind: :plain, symbol: "SPY"}
    assert a == b
  end
end
