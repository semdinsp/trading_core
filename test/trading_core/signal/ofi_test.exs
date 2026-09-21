defmodule TradingCore.Signal.OfiTest do
  use ExUnit.Case, async: true

  alias TradingCore.Signal.{Compute, Spec}

  @now ~U[2026-09-21 14:00:00Z]

  defp run(params, ticks) do
    spec = %Spec{kind: :ofi, symbol: "SPY", params: params}
    {:ok, state} = Compute.init(spec)

    Enum.reduce(ticks, {state, :warming_up}, fn tick, {acc, _} ->
      Compute.step(spec, acc, tick)
    end)
  end

  defp book(i, bid, bid_size, ask, ask_size) do
    %{
      at: DateTime.add(@now, i, :second),
      value: nil,
      bid: bid,
      bid_size: bid_size,
      ask: ask,
      ask_size: ask_size
    }
  end

  # bid 100.00 x500, ask 100.02 x500
  defp base, do: book(0, 100.0, 500, 100.02, 500)

  describe "the six CKS price-direction cases" do
    test "bid price rises: the whole new bid size is new liquidity" do
      {_s, value} = run(%{}, [base(), book(1, 100.01, 300, 100.02, 500)])

      assert Decimal.equal?(value, Decimal.new(300))
    end

    test "bid price falls: the whole previous level was pulled" do
      {_s, value} = run(%{}, [base(), book(1, 99.99, 300, 100.02, 500)])

      assert Decimal.equal?(value, Decimal.new(-500))
    end

    test "bid price unchanged: only the change in resting size counts" do
      {_s, value} = run(%{}, [base(), book(1, 100.0, 800, 100.02, 500)])

      assert Decimal.equal?(value, Decimal.new(300))
    end

    test "ask price falls: sellers undercutting is BUY-side pressure" do
      # The sign inversion that makes OFI asymmetric. An ask falling
      # subtracts a negative, so it contributes positively.
      {_s, value} = run(%{}, [base(), book(1, 100.0, 500, 100.01, 200)])

      assert Decimal.equal?(value, Decimal.new(500))
    end

    test "ask price rises: new ask liquidity is sell-side pressure" do
      {_s, value} = run(%{}, [base(), book(1, 100.0, 500, 100.03, 700)])

      assert Decimal.equal?(value, Decimal.new(-700))
    end

    test "ask price unchanged: added ask size is sell-side pressure" do
      {_s, value} = run(%{}, [base(), book(1, 100.0, 500, 100.02, 900)])

      assert Decimal.equal?(value, Decimal.new(-400))
    end
  end

  describe "both sides moving together" do
    test "bid up and ask up nets the two contributions" do
      # bid rises: +300. ask rises: -700. Net -400.
      {_s, value} = run(%{}, [base(), book(1, 100.01, 300, 100.03, 700)])

      assert Decimal.equal?(value, Decimal.new(-400))
    end

    test "a book tightening from both sides is strongly positive" do
      # bid rises (+400), ask falls (+500 after inversion) = +900
      {_s, value} = run(%{}, [base(), book(1, 100.01, 400, 100.01, 200)])

      assert Decimal.equal?(value, Decimal.new(900))
    end

    test "an unchanged book contributes exactly zero" do
      {_s, value} = run(%{}, [base(), book(1, 100.0, 500, 100.02, 500)])

      assert Decimal.equal?(value, Decimal.new(0))
    end
  end

  describe "windowing" do
    test "sums contributions across several updates" do
      ticks = [
        base(),
        # +300
        book(1, 100.01, 300, 100.02, 500),
        # bid unchanged, size 300 -> 500 = +200
        book(2, 100.01, 500, 100.02, 500)
      ]

      {_s, value} = run(%{}, ticks)

      assert Decimal.equal?(value, Decimal.new(500))
    end

    test "old contributions roll off the window" do
      spec = %Spec{kind: :ofi, symbol: "SPY", window_ms: 5_000}
      {:ok, state} = Compute.init(spec)

      ticks = [
        base(),
        book(1, 100.01, 300, 100.02, 500),
        # 60s later, outside a 5s window
        book(60, 100.02, 400, 100.03, 500)
      ]

      {state, _value} =
        Enum.reduce(ticks, {state, :warming_up}, fn tick, {acc, _} ->
          Compute.step(spec, acc, tick)
        end)

      assert length(state.history) == 1
    end
  end

  describe "warm-up and partial books" do
    test "the first complete book has nothing to difference against" do
      {_s, value} = run(%{}, [base()])

      assert value == :warming_up
    end

    test "the first book is recorded so the second update can use it" do
      {state, _value} = run(%{}, [base()])

      assert state.prev != nil
    end

    test "an incomplete book is warming up" do
      {_s, value} = run(%{}, [%{at: @now, value: nil, bid: 100.0, bid_size: 500}])

      assert value == :warming_up
    end

    test "one-sided updates still build a book, then contribute" do
      # The IBKR shape: bid, then ask, then a bid update.
      ticks = [
        %{at: @now, value: nil, bid: 100.0, bid_size: 500},
        %{at: DateTime.add(@now, 1, :second), value: nil, ask: 100.02, ask_size: 500},
        %{at: DateTime.add(@now, 2, :second), value: nil, bid: 100.01, bid_size: 300}
      ]

      {_s, value} = run(%{}, ticks)

      assert Decimal.equal?(value, Decimal.new(300))
    end

    test "a stale pairing is refused when bounded" do
      stale = DateTime.add(@now, 60, :second)

      ticks = [
        %{at: @now, value: nil, ask: 100.02, ask_size: 500},
        %{at: stale, value: nil, bid: 100.0, bid_size: 500}
      ]

      {_s, value} = run(%{"max_quote_staleness_ms" => 5_000}, ticks)

      assert value == :warming_up
    end

    test "a trade-only tick does not disturb the book" do
      ticks = [
        base(),
        %{at: DateTime.add(@now, 1, :second), value: 100.01},
        book(2, 100.01, 300, 100.02, 500)
      ]

      {_s, value} = run(%{}, ticks)

      assert Decimal.equal?(value, Decimal.new(300))
    end
  end

  describe "spec wiring" do
    test "ofi is a base kind and enumerated" do
      assert Spec.base_kind?(:ofi)
      refute Spec.single_parent_kind?(:ofi)
      refute Spec.dual_parent_kind?(:ofi)
      assert :ofi in Spec.kinds()
    end
  end
end
