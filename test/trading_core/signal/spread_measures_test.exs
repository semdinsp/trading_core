defmodule TradingCore.Signal.SpreadMeasuresTest do
  use ExUnit.Case, async: true

  alias TradingCore.Signal.{Compute, Spec}

  @now ~U[2026-09-21 14:00:00Z]

  defp run(kind, params, ticks) do
    spec = %Spec{kind: kind, symbol: "SPY", params: params}
    {:ok, state} = Compute.init(spec)

    Enum.reduce(ticks, {state, :warming_up}, fn tick, {acc, _} ->
      Compute.step(spec, acc, tick)
    end)
  end

  # bid 99.98 / ask 100.02 => spread 0.04, mid 100.00
  defp book(at \\ @now), do: %{at: at, value: nil, bid: 99.98, ask: 100.02}

  describe "quoted_spread" do
    test "absolute form is ask - bid" do
      {_s, value} = run(:quoted_spread, %{}, [book()])

      assert Decimal.equal?(value, Decimal.new("0.04"))
    end

    test "relative form divides by mid" do
      # 0.04 / 100.00 = 0.0004
      {_s, value} = run(:quoted_spread, %{"relative" => true}, [book()])

      assert Decimal.equal?(value, Decimal.new("0.0004"))
    end

    test "precision rounds the emitted value" do
      {_s, value} = run(:quoted_spread, %{"relative" => true, "precision" => 5}, [book()])

      assert Decimal.equal?(value, Decimal.new("0.00040"))
    end

    test "a wider book gives a larger spread -- the liquidity-regime signal" do
      tight = %{at: @now, bid: 99.99, ask: 100.01}
      wide = %{at: @now, bid: 99.50, ask: 100.50}

      {_s, tight_value} = run(:quoted_spread, %{}, [tight])
      {_s, wide_value} = run(:quoted_spread, %{}, [wide])

      assert Decimal.compare(wide_value, tight_value) == :gt
    end

    test "warming up until both sides are known" do
      {_s, value} = run(:quoted_spread, %{}, [%{at: @now, bid: 99.98}])

      assert value == :warming_up
    end

    test "a crossed book is bad data, not a negative spread" do
      crossed = %{at: @now, bid: 100.05, ask: 100.02}

      {_s, value} = run(:quoted_spread, %{}, [crossed])

      assert value == :warming_up
    end

    test "a locked book is refused rather than reported as zero" do
      # Emitting 0.0 would be indistinguishable from an infinitely tight
      # real market, which is a materially different claim.
      locked = %{at: @now, bid: 100.00, ask: 100.00}

      {_s, value} = run(:quoted_spread, %{}, [locked])

      assert value == :warming_up
    end

    test "a stale pairing is refused when bounded" do
      stale = DateTime.add(@now, 60, :second)

      ticks = [
        %{at: @now, ask: 100.02},
        %{at: stale, bid: 99.98}
      ]

      {_s, value} = run(:quoted_spread, %{"max_quote_staleness_ms" => 5_000}, ticks)

      assert value == :warming_up
    end
  end

  describe "effective_spread" do
    test "a trade at the ask costs the full half-spread, doubled" do
      # |100.02 - 100.00| * 2 = 0.04
      {_s, value} = run(:effective_spread, %{}, [book(), %{at: @now, value: 100.02}])

      assert Decimal.equal?(value, Decimal.new("0.04"))
    end

    test "a trade at the bid costs the same, by symmetry" do
      {_s, value} = run(:effective_spread, %{}, [book(), %{at: @now, value: 99.98}])

      assert Decimal.equal?(value, Decimal.new("0.04"))
    end

    test "a trade at mid costs nothing" do
      {_s, value} = run(:effective_spread, %{}, [book(), %{at: @now, value: 100.00}])

      assert Decimal.equal?(value, Decimal.new(0))
    end

    test "price improvement inside the spread costs less than quoted" do
      # A print at 100.01 is inside the 99.98/100.02 book: effective
      # 0.02 against a quoted 0.04. This gap is the whole reason
      # effective spread exists as a separate measure.
      {_s, effective} = run(:effective_spread, %{}, [book(), %{at: @now, value: 100.01}])
      {_s, quoted} = run(:quoted_spread, %{}, [book()])

      assert Decimal.equal?(effective, Decimal.new("0.02"))
      assert Decimal.compare(effective, quoted) == :lt
    end

    test "a print outside the book costs more than quoted" do
      {_s, effective} = run(:effective_spread, %{}, [book(), %{at: @now, value: 100.10}])

      assert Decimal.equal?(effective, Decimal.new("0.20"))
    end

    test "relative form divides by mid" do
      # 0.04 / 100.00
      {_s, value} =
        run(:effective_spread, %{"relative" => true}, [book(), %{at: @now, value: 100.02}])

      assert Decimal.equal?(value, Decimal.new("0.0004"))
    end

    test "a quote-only tick updates the book but emits nothing" do
      # There is no execution to measure, so :warming_up rather than
      # re-reporting the previous trade's cost.
      {state, value} = run(:effective_spread, %{}, [book()])

      assert value == :warming_up
      assert Compute.quote_ready?(state.quote, nil)
    end

    test "a trade before any book is known is warming up" do
      {_s, value} = run(:effective_spread, %{}, [%{at: @now, value: 100.02}])

      assert value == :warming_up
    end

    test "a crossed book makes the mid meaningless, so no value" do
      ticks = [%{at: @now, bid: 100.05, ask: 100.02}, %{at: @now, value: 100.03}]

      {_s, value} = run(:effective_spread, %{}, ticks)

      assert value == :warming_up
    end

    test "the book updates between trades, so each trade uses the prevailing mid" do
      t1 = @now
      t2 = DateTime.add(@now, 1, :second)

      ticks = [
        book(t1),
        %{at: t1, value: 100.02},
        # book shifts up: 100.08/100.12, mid 100.10
        %{at: t2, bid: 100.08, ask: 100.12},
        %{at: t2, value: 100.12}
      ]

      {_s, value} = run(:effective_spread, %{}, ticks)

      # |100.12 - 100.10| * 2 = 0.04 against the NEW book, not the old one
      assert Decimal.equal?(value, Decimal.new("0.04"))
    end
  end

  describe "spec wiring" do
    test "both are base kinds and enumerated" do
      for kind <- [:quoted_spread, :effective_spread] do
        assert Spec.base_kind?(kind)
        refute Spec.single_parent_kind?(kind)
        refute Spec.dual_parent_kind?(kind)
        assert kind in Spec.kinds()
      end
    end
  end
end
