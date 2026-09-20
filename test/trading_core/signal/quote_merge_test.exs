defmodule TradingCore.Signal.QuoteMergeTest do
  use ExUnit.Case, async: true

  alias TradingCore.Signal.Compute

  @now ~U[2026-09-20 14:30:00Z]

  describe "new_quote_state/0" do
    test "starts with both sides unknown" do
      state = Compute.new_quote_state()

      assert state.bid == nil
      assert state.ask == nil
      assert state.bid_size == nil
      assert state.ask_size == nil
      assert state.bid_at == nil
      assert state.ask_at == nil
    end
  end

  describe "merge_quote/3 with a snapshot provider (Polygon/Massive)" do
    test "all four fields on one tick populate both sides at once" do
      tick = %{at: @now, value: 100, bid: 99.98, ask: 100.02, bid_size: 500, ask_size: 300}

      state = Compute.merge_quote(Compute.new_quote_state(), tick, @now)

      assert Decimal.equal?(state.bid, Decimal.from_float(99.98))
      assert Decimal.equal?(state.ask, Decimal.from_float(100.02))
      assert Decimal.equal?(state.bid_size, Decimal.new(500))
      assert Decimal.equal?(state.ask_size, Decimal.new(300))
      assert state.bid_at == @now
      assert state.ask_at == @now
    end

    test "both sides share a timestamp, so any staleness bound passes" do
      tick = %{at: @now, value: 100, bid: 99.98, ask: 100.02, bid_size: 500, ask_size: 300}
      state = Compute.merge_quote(Compute.new_quote_state(), tick, @now)

      assert Compute.quote_ready?(state, 1)
      assert Compute.quote_ready?(state, nil)
    end
  end

  describe "merge_quote/3 with a partial-update provider (IBKR)" do
    test "a bid-only tick populates the bid and leaves the ask unknown" do
      tick = %{at: @now, value: nil, bid: 99.98, bid_size: 500}

      state = Compute.merge_quote(Compute.new_quote_state(), tick, @now)

      assert Decimal.equal?(state.bid, Decimal.from_float(99.98))
      assert state.ask == nil
      assert state.bid_at == @now
      assert state.ask_at == nil
    end

    test "a later ask-only tick completes the book without disturbing the bid" do
      # The exact IBKR pattern: %{bid:, bid_size:} then %{ask:, ask_size:}.
      later = DateTime.add(@now, 1, :second)

      state =
        Compute.new_quote_state()
        |> Compute.merge_quote(%{at: @now, value: nil, bid: 99.98, bid_size: 500}, @now)
        |> Compute.merge_quote(%{at: later, value: nil, ask: 100.02, ask_size: 300}, later)

      assert Decimal.equal?(state.bid, Decimal.from_float(99.98))
      assert Decimal.equal?(state.bid_size, Decimal.new(500))
      assert Decimal.equal?(state.ask, Decimal.from_float(100.02))
      assert Decimal.equal?(state.ask_size, Decimal.new(300))
      assert state.bid_at == @now
      assert state.ask_at == later
    end

    test "a side updates only when its price is present -- size alone is not a quote" do
      # A size with no price cannot be compared against anything, so it
      # must not establish a side or stamp a time.
      state = Compute.merge_quote(Compute.new_quote_state(), %{at: @now, bid_size: 500}, @now)

      assert state.bid == nil
      assert state.bid_size == nil
      assert state.bid_at == nil
    end

    test "a price with no size still establishes the side" do
      state = Compute.merge_quote(Compute.new_quote_state(), %{at: @now, bid: 99.98}, @now)

      assert Decimal.equal?(state.bid, Decimal.from_float(99.98))
      assert state.bid_size == nil
      assert state.bid_at == @now
    end

    test "a later tick on one side replaces that side's price and size together" do
      later = DateTime.add(@now, 1, :second)

      state =
        Compute.new_quote_state()
        |> Compute.merge_quote(%{at: @now, bid: 99.98, bid_size: 500}, @now)
        |> Compute.merge_quote(%{at: later, bid: 99.99, bid_size: 700}, later)

      assert Decimal.equal?(state.bid, Decimal.from_float(99.99))
      assert Decimal.equal?(state.bid_size, Decimal.new(700))
      assert state.bid_at == later
    end

    test "a tick carrying neither side leaves the book untouched" do
      before = Compute.merge_quote(Compute.new_quote_state(), %{at: @now, bid: 99.98}, @now)

      after_trade =
        Compute.merge_quote(before, %{at: DateTime.add(@now, 1, :second), value: 100}, @now)

      assert after_trade == before
    end
  end

  describe "quote_ready?/2" do
    test "false until both sides are known" do
      empty = Compute.new_quote_state()
      bid_only = Compute.merge_quote(empty, %{at: @now, bid: 99.98, bid_size: 500}, @now)

      refute Compute.quote_ready?(empty, nil)
      refute Compute.quote_ready?(bid_only, nil)
    end

    test "true once both sides are known, with no bound" do
      state =
        Compute.new_quote_state()
        |> Compute.merge_quote(%{at: @now, bid: 99.98, bid_size: 500}, @now)
        |> Compute.merge_quote(%{at: @now, ask: 100.02, ask_size: 300}, @now)

      assert Compute.quote_ready?(state, nil)
    end

    test "a bound rejects sides that printed too far apart" do
      # Fresh bid against an ask from a minute ago describes a book that
      # existed at no instant. The failure is silent -- the arithmetic is
      # valid and the number looks ordinary -- so the bound is the only
      # thing standing between a stale pairing and an invented reading.
      stale = DateTime.add(@now, 60, :second)

      state =
        Compute.new_quote_state()
        |> Compute.merge_quote(%{at: @now, ask: 100.02, ask_size: 300}, @now)
        |> Compute.merge_quote(%{at: stale, bid: 99.98, bid_size: 500}, stale)

      refute Compute.quote_ready?(state, 5_000)
      # ...and unbounded still accepts it, which is why a partial-update
      # caller must set the bound.
      assert Compute.quote_ready?(state, nil)
    end

    test "a bound admits sides that printed close together" do
      close = DateTime.add(@now, 100, :millisecond)

      state =
        Compute.new_quote_state()
        |> Compute.merge_quote(%{at: @now, ask: 100.02, ask_size: 300}, @now)
        |> Compute.merge_quote(%{at: close, bid: 99.98, bid_size: 500}, close)

      assert Compute.quote_ready?(state, 5_000)
    end

    test "the bound is symmetric -- order of arrival does not matter" do
      stale = DateTime.add(@now, 60, :second)

      bid_first =
        Compute.new_quote_state()
        |> Compute.merge_quote(%{at: @now, bid: 99.98}, @now)
        |> Compute.merge_quote(%{at: stale, ask: 100.02}, stale)

      ask_first =
        Compute.new_quote_state()
        |> Compute.merge_quote(%{at: @now, ask: 100.02}, @now)
        |> Compute.merge_quote(%{at: stale, bid: 99.98}, stale)

      refute Compute.quote_ready?(bid_first, 5_000)
      refute Compute.quote_ready?(ask_first, 5_000)
    end
  end

  describe "existing kinds are unaffected by quote fields on the tick" do
    alias TradingCore.Signal.Spec

    test "a plain kind ignores book fields entirely" do
      spec = %Spec{kind: :plain, symbol: "SPY"}
      {:ok, state} = Compute.init(spec)

      without = Compute.step(spec, state, %{at: @now, value: 100})

      with_book =
        Compute.step(spec, state, %{
          at: @now,
          value: 100,
          bid: 99.98,
          ask: 100.02,
          bid_size: 500,
          ask_size: 300
        })

      assert without == with_book
    end

    test "a momentum kind ignores book fields entirely" do
      spec = %Spec{kind: :momentum, symbol: "SPY", window_ms: :timer.minutes(5)}
      {:ok, state} = Compute.init(spec)

      {state_a, _} = Compute.step(spec, state, %{at: @now, value: 100})
      {state_b, _} = Compute.step(spec, state, %{at: @now, value: 100, bid: 99.9, ask: 100.1})

      assert state_a == state_b
    end
  end
end
