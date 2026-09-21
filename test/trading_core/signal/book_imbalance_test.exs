defmodule TradingCore.Signal.BookImbalanceTest do
  use ExUnit.Case, async: true

  alias TradingCore.Signal.{Compute, Spec}

  @now ~U[2026-09-20 14:30:00Z]

  defp spec(params \\ %{}), do: %Spec{kind: :book_imbalance, symbol: "SPY", params: params}

  defp step_all(spec, ticks) do
    {:ok, state} = Compute.init(spec)

    Enum.reduce(ticks, {state, :warming_up}, fn tick, {acc, _} ->
      Compute.step(spec, acc, tick)
    end)
  end

  defp snapshot(bid_size, ask_size, at \\ @now) do
    %{at: at, value: 100, bid: 99.98, ask: 100.02, bid_size: bid_size, ask_size: ask_size}
  end

  describe "the ratio itself" do
    test "a bid-heavy book is positive" do
      # (700 - 300) / 1000 = 0.4
      {_state, value} = step_all(spec(), [snapshot(700, 300)])

      assert Decimal.equal?(value, Decimal.new("0.4"))
    end

    test "an ask-heavy book is negative" do
      # (300 - 700) / 1000 = -0.4
      {_state, value} = step_all(spec(), [snapshot(300, 700)])

      assert Decimal.equal?(value, Decimal.new("-0.4"))
    end

    test "a balanced book is exactly zero" do
      {_state, value} = step_all(spec(), [snapshot(500, 500)])

      assert Decimal.equal?(value, Decimal.new(0))
    end

    test "all bid size is the +1.0 boundary" do
      {_state, value} = step_all(spec(), [snapshot(500, 0)])

      assert Decimal.equal?(value, Decimal.new(1))
    end

    test "all ask size is the -1.0 boundary" do
      {_state, value} = step_all(spec(), [snapshot(0, 500)])

      assert Decimal.equal?(value, Decimal.new(-1))
    end

    test "the value never leaves -1.0..1.0 across a range of books" do
      for {b, a} <- [{1, 9999}, {9999, 1}, {1, 1}, {12_345, 678}] do
        {_state, value} = step_all(spec(), [snapshot(b, a)])

        assert Decimal.compare(value, Decimal.new(-1)) != :lt
        assert Decimal.compare(value, Decimal.new(1)) != :gt
      end
    end

    test "precision rounds the emitted value when asked" do
      # (700 - 600) / 1300 = 0.0769230...
      {_state, value} = step_all(spec(%{"precision" => 4}), [snapshot(700, 600)])

      assert Decimal.equal?(value, Decimal.new("0.0769"))
    end
  end

  describe "warming up rather than emitting a misleading number" do
    test "an empty book is warming up" do
      {:ok, state} = Compute.init(spec())

      {_state, value} = Compute.step(spec(), state, %{at: @now, value: 100})

      assert value == :warming_up
    end

    test "one side only is warming up" do
      tick = %{at: @now, value: nil, bid: 99.98, bid_size: 500}

      {_state, value} = step_all(spec(), [tick])

      assert value == :warming_up
    end

    test "a price with no size on one side is warming up" do
      # A side can be established by price alone, but the ratio needs
      # sizes -- so the book is "ready" yet still unmeasurable.
      ticks = [
        %{at: @now, value: nil, bid: 99.98, bid_size: 500},
        %{at: @now, value: nil, ask: 100.02}
      ]

      {state, value} = step_all(spec(), ticks)

      assert Compute.quote_ready?(state.quote, nil), "both sides should be known"
      assert value == :warming_up, "but with no ask size there is no ratio"
    end

    test "zero total depth is warming up, NOT a balanced book" do
      # 0/0 must not become 0.0 -- an empty book and a perfectly balanced
      # one would then be indistinguishable downstream.
      {_state, value} = step_all(spec(), [snapshot(0, 0)])

      assert value == :warming_up
    end
  end

  describe "partial-update feeds (IBKR)" do
    test "a bid tick then an ask tick completes the book and emits" do
      later = DateTime.add(@now, 1, :second)

      ticks = [
        %{at: @now, value: nil, bid: 99.98, bid_size: 700},
        %{at: later, value: nil, ask: 100.02, ask_size: 300}
      ]

      {_state, value} = step_all(spec(), ticks)

      assert Decimal.equal?(value, Decimal.new("0.4"))
    end

    test "a later one-sided tick updates that side and re-emits" do
      t1 = @now
      t2 = DateTime.add(@now, 1, :second)

      ticks = [
        snapshot(500, 500, t1),
        %{at: t2, value: nil, bid: 99.99, bid_size: 1500}
      ]

      # Ask size stays at 500 from the snapshot: (1500-500)/2000 = 0.5
      {_state, value} = step_all(spec(), ticks)

      assert Decimal.equal?(value, Decimal.new("0.5"))
    end

    test "the staleness bound refuses a pairing whose sides printed far apart" do
      stale = DateTime.add(@now, 60, :second)

      ticks = [
        %{at: @now, value: nil, ask: 100.02, ask_size: 300},
        %{at: stale, value: nil, bid: 99.98, bid_size: 700}
      ]

      {_state, value} = step_all(spec(%{"max_quote_staleness_ms" => 5_000}), ticks)

      assert value == :warming_up
    end

    test "the same pairing emits when it is inside the bound" do
      close = DateTime.add(@now, 100, :millisecond)

      ticks = [
        %{at: @now, value: nil, ask: 100.02, ask_size: 300},
        %{at: close, value: nil, bid: 99.98, bid_size: 700}
      ]

      {_state, value} = step_all(spec(%{"max_quote_staleness_ms" => 5_000}), ticks)

      assert Decimal.equal?(value, Decimal.new("0.4"))
    end

    test "unbounded is the default, so a stale pairing still emits" do
      # Documented behaviour, not an accident: a snapshot-feed caller wants
      # this, and a partial-update caller must set the bound.
      stale = DateTime.add(@now, 3600, :second)

      ticks = [
        %{at: @now, value: nil, ask: 100.02, ask_size: 300},
        %{at: stale, value: nil, bid: 99.98, bid_size: 700}
      ]

      {_state, value} = step_all(spec(), ticks)

      assert %Decimal{} = value
    end
  end

  describe "spec wiring" do
    test "book_imbalance is a base kind" do
      assert Spec.base_kind?(:book_imbalance)
      refute Spec.single_parent_kind?(:book_imbalance)
      refute Spec.dual_parent_kind?(:book_imbalance)
      assert :book_imbalance in Spec.kinds()
    end

    test "a trade-only tick leaves an established book intact" do
      ticks = [snapshot(700, 300), %{at: DateTime.add(@now, 1, :second), value: 100.5}]

      {_state, value} = step_all(spec(), ticks)

      assert Decimal.equal?(value, Decimal.new("0.4"))
    end
  end
end
