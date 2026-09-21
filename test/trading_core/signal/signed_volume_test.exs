defmodule TradingCore.Signal.SignedVolumeTest do
  use ExUnit.Case, async: true

  alias TradingCore.Signal.{Compute, Spec}

  @now ~U[2026-09-21 14:00:00Z]

  defp run(params, ticks) do
    spec = %Spec{kind: :signed_volume, symbol: "SPY", params: params}
    {:ok, state} = Compute.init(spec)

    Enum.reduce(ticks, {state, :warming_up}, fn tick, {acc, _} ->
      Compute.step(spec, acc, tick)
    end)
  end

  defp trade(i, price, volume), do: %{at: at(i), value: price, volume: volume}
  defp quote_tick(i, bid, ask), do: %{at: at(i), value: nil, bid: bid, ask: ask}
  defp at(i), do: DateTime.add(@now, i, :second)

  describe "tick_rule (default classifier)" do
    test "an uptick is buyer-initiated, a downtick seller-initiated" do
      # first trade unsigned; +100 (up), -100 (down) => 0
      {_s, value} =
        run(%{}, [trade(0, 100.0, 100), trade(1, 100.1, 100), trade(2, 100.0, 100)])

      assert Decimal.equal?(value, Decimal.new(0))
    end

    test "nets buys against sells over the window" do
      # unsigned, +100, +100, -100 => +100
      {_s, value} =
        run(%{}, [
          trade(0, 100.0, 100),
          trade(1, 100.1, 100),
          trade(2, 100.2, 100),
          trade(3, 100.0, 100)
        ])

      assert Decimal.equal?(value, Decimal.new(100))
    end

    test "an unchanged price carries the previous sign forward" do
      # A zero-tick inherits rather than counting as neutral: a trade at
      # an unchanged price is attributed to whichever side was pressing
      # last. Treating it as 0 would understate flow on a quiet tape
      # where most prints repeat.
      {_s, value} = run(%{}, [trade(0, 100.0, 50), trade(1, 100.1, 50), trade(2, 100.1, 50)])

      # +50 (up) then +50 (carried) = 100
      assert Decimal.equal?(value, Decimal.new(100))
    end

    test "a carried sell sign stays negative" do
      {_s, value} = run(%{}, [trade(0, 100.0, 50), trade(1, 99.9, 50), trade(2, 99.9, 50)])

      assert Decimal.equal?(value, Decimal.new(-100))
    end

    test "the first trade is warming up -- nothing to sign it against" do
      {_s, value} = run(%{}, [trade(0, 100.0, 100)])

      assert value == :warming_up
    end

    test "the first trade still sets the reference for the second" do
      {_s, value} = run(%{}, [trade(0, 100.0, 100), trade(1, 100.5, 100)])

      assert Decimal.equal?(value, Decimal.new(100))
    end

    test "needs no quote data at all" do
      {state, value} = run(%{}, [trade(0, 100.0, 10), trade(1, 100.1, 10)])

      refute Compute.quote_ready?(state.quote, nil)
      assert Decimal.equal?(value, Decimal.new(10))
    end

    test "volume defaults to 1 when the tick carries none" do
      ticks = [%{at: at(0), value: 100.0}, %{at: at(1), value: 100.1}]

      {_s, value} = run(%{}, ticks)

      assert Decimal.equal?(value, Decimal.new(1))
    end

    # Regression: found by replaying live SPY ticks. Map.get/3's default
    # only fires on an ABSENT key, but the real feed sends volume: nil on
    # a trade carrying no size, which crashed Decimal.mult/2. Both
    # spellings of "no size" must mean the same thing.
    test "an explicit nil volume is treated as unsized, not as a crash" do
      ticks = [
        %{at: at(0), value: 100.0, volume: nil},
        %{at: at(1), value: 100.1, volume: nil}
      ]

      {_s, value} = run(%{}, ticks)

      assert Decimal.equal?(value, Decimal.new(1))
    end
  end

  describe "lee_ready" do
    @params %{"classifier" => "lee_ready"}

    test "a trade above the mid is buyer-initiated" do
      # bid 99.98 / ask 100.02 => mid 100.00
      {_s, value} = run(@params, [quote_tick(0, 99.98, 100.02), trade(1, 100.02, 200)])

      assert Decimal.equal?(value, Decimal.new(200))
    end

    test "a trade below the mid is seller-initiated" do
      {_s, value} = run(@params, [quote_tick(0, 99.98, 100.02), trade(1, 99.98, 200)])

      assert Decimal.equal?(value, Decimal.new(-200))
    end

    test "signs the very first trade, unlike tick_rule -- the quote is the reference" do
      {_s, tick_rule_value} = run(%{}, [quote_tick(0, 99.98, 100.02), trade(1, 100.02, 200)])
      {_s, lee_value} = run(@params, [quote_tick(0, 99.98, 100.02), trade(1, 100.02, 200)])

      assert tick_rule_value == :warming_up
      assert Decimal.equal?(lee_value, Decimal.new(200))
    end

    test "a trade exactly at mid falls back to the tick rule" do
      ticks = [
        quote_tick(0, 99.98, 100.02),
        # signs as a buy off the quote
        trade(1, 100.02, 100),
        # exactly at mid: tick rule sees a downtick from 100.02 => sell
        trade(2, 100.00, 100)
      ]

      {_s, value} = run(@params, ticks)

      assert Decimal.equal?(value, Decimal.new(0))
    end

    test "falls back to the tick rule with no quote available" do
      {_s, value} = run(@params, [trade(0, 100.0, 100), trade(1, 100.1, 100)])

      assert Decimal.equal?(value, Decimal.new(100))
    end

    test "falls back to the tick rule on a crossed book" do
      # A crossed book makes the mid meaningless, so it must not be used
      # to classify -- same guard the spread kinds apply.
      ticks = [
        quote_tick(0, 100.05, 100.02),
        trade(1, 100.0, 100),
        trade(2, 100.1, 100)
      ]

      {_s, value} = run(@params, ticks)

      assert Decimal.equal?(value, Decimal.new(100))
    end

    test "a quote-only tick is not an execution" do
      {_s, value} = run(@params, [quote_tick(0, 99.98, 100.02)])

      assert value == :warming_up
    end
  end

  describe "classifier validation" do
    test "an unrecognised classifier raises at init, not mid-stream" do
      assert_raise ArgumentError, ~r/unknown classifier/, fn ->
        Compute.init(%Spec{kind: :signed_volume, params: %{"classifier" => "bogus"}})
      end
    end

    test "tick_rule is the default" do
      explicit = run(%{"classifier" => "tick_rule"}, [trade(0, 100.0, 10), trade(1, 100.1, 10)])
      default = run(%{}, [trade(0, 100.0, 10), trade(1, 100.1, 10)])

      assert elem(explicit, 1) == elem(default, 1)
    end
  end

  describe "windowing" do
    test "old contributions roll off the window" do
      spec = %Spec{kind: :signed_volume, symbol: "SPY", window_ms: 5_000}
      {:ok, state} = Compute.init(spec)

      ticks = [
        trade(0, 100.0, 100),
        trade(1, 100.1, 100),
        # 60s later: the earlier contribution is outside a 5s window
        trade(60, 100.2, 100)
      ]

      {state, value} =
        Enum.reduce(ticks, {state, :warming_up}, fn tick, {acc, _} ->
          Compute.step(spec, acc, tick)
        end)

      assert length(state.history) == 1
      assert Decimal.equal?(value, Decimal.new(100))
    end
  end

  describe "spec wiring" do
    test "signed_volume is a base kind and enumerated" do
      assert Spec.base_kind?(:signed_volume)
      refute Spec.single_parent_kind?(:signed_volume)
      refute Spec.dual_parent_kind?(:signed_volume)
      assert :signed_volume in Spec.kinds()
    end
  end
end
