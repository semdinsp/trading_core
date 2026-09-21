defmodule TradingCore.Signal.KyleLambdaTest do
  use ExUnit.Case, async: true

  alias TradingCore.Signal.{Compute, Spec}

  @now ~U[2026-09-21 14:00:00Z]

  defp spec(params \\ %{}) do
    %Spec{
      kind: :kyle_lambda,
      symbol: "SPY",
      params: Map.merge(%{"classifier" => "lee_ready"}, params)
    }
  end

  defp run(spec, ticks) do
    {:ok, state} = Compute.init(spec)

    Enum.reduce(ticks, {state, :warming_up}, fn tick, {acc, _} ->
      Compute.step(spec, acc, tick)
    end)
  end

  defp all_values(spec, ticks) do
    {:ok, state} = Compute.init(spec)

    {_state, vals} =
      Enum.reduce(ticks, {state, []}, fn tick, {acc, out} ->
        {next, v} = Compute.step(spec, acc, tick)
        {next, [v | out]}
      end)

    Enum.reverse(vals)
  end

  defp quote_at(i, bid, ask),
    do: %{at: DateTime.add(@now, i, :second), value: nil, bid: bid, ask: ask}

  defp trade_at(i, price, volume),
    do: %{at: DateTime.add(@now, i, :second), value: price, volume: volume}

  # Signed volume drives the mid linearly: ~0.1% mid move per 100 shares,
  # so impact per share is ~1e-5 and lambda should recover that.
  defp linear_impact_ticks do
    [
      quote_at(0, 99.99, 100.01),
      trade_at(1, 100.01, 100),
      quote_at(2, 100.09, 100.11),
      trade_at(3, 100.11, 200),
      quote_at(4, 100.29, 100.31),
      trade_at(5, 100.31, 300),
      quote_at(6, 100.59, 100.61),
      trade_at(7, 100.61, 400)
    ]
  end

  describe "the slope itself" do
    test "recovers the price impact per unit of signed volume" do
      {_state, value} = run(spec(), linear_impact_ticks())

      # ~1e-5 mid-return per share.
      assert_in_delta Decimal.to_float(value), 1.0e-5, 2.0e-6
    end

    test "is positive when buys push the mid up" do
      {_state, value} = run(spec(), linear_impact_ticks())

      assert Decimal.compare(value, Decimal.new(0)) == :gt
    end

    test "a thinner book gives a larger lambda than a deeper one" do
      # Same signed volumes, twice the mid move => twice the impact.
      thin = [
        quote_at(0, 99.99, 100.01),
        trade_at(1, 100.01, 100),
        quote_at(2, 100.19, 100.21),
        trade_at(3, 100.21, 200),
        quote_at(4, 100.59, 100.61),
        trade_at(5, 100.61, 300)
      ]

      {_s, deep_value} = run(spec(), linear_impact_ticks())
      {_s, thin_value} = run(spec(), thin)

      assert Decimal.compare(thin_value, deep_value) == :gt
    end

    test "sell flow pushing the mid down still gives a positive lambda" do
      # Impact is directionless: negative signed volume paired with
      # negative mid returns is the same positive slope. Sizes grow and
      # the mid moves PROPORTIONALLY further each time (-0.1%, -0.2%,
      # -0.3%), which is what makes the slope positive -- a fixture where
      # bigger sells moved the mid less would correctly fit a negative
      # lambda, because that is not price impact.
      ticks = [
        quote_at(0, 100.59, 100.61),
        # sell 100, mid 100.60 -> 100.50 (-0.1%)
        trade_at(1, 100.59, 100),
        quote_at(2, 100.49, 100.51),
        # sell 200, mid 100.50 -> 100.30 (-0.2%)
        trade_at(3, 100.49, 200),
        quote_at(4, 100.29, 100.31),
        # sell 300, mid 100.30 -> 100.00 (-0.3%)
        trade_at(5, 100.29, 300)
      ]

      {_state, value} = run(spec(), ticks)

      assert Decimal.compare(value, Decimal.new(0)) == :gt
      # Matches the buy-side magnitude: impact is directionless.
      assert_in_delta Decimal.to_float(value), 1.0e-5, 2.0e-6
    end
  end

  describe "degenerate and warm-up cases" do
    test "flat signed volume has no variation to fit a slope to" do
      # rolling_ols_beta/4 returns nil on zero x-variance, which is the
      # right answer: identical signed volume on every trade says nothing
      # about impact, and a slope fitted to it is meaningless.
      ticks = [
        quote_at(0, 99.99, 100.01),
        trade_at(1, 100.01, 100),
        quote_at(2, 100.09, 100.11),
        trade_at(3, 100.11, 100),
        quote_at(4, 100.19, 100.21),
        trade_at(5, 100.21, 100)
      ]

      {_state, value} = run(spec(), ticks)

      assert value == :warming_up
    end

    test "a single observation is not enough" do
      {_state, value} = run(spec(), [quote_at(0, 99.99, 100.01), trade_at(1, 100.01, 100)])

      assert value == :warming_up
    end

    test "a trade with no prior mid has nothing to measure the move against" do
      {_state, value} = run(spec(), [trade_at(0, 100.01, 100)])

      assert value == :warming_up
    end

    test "a quote-only tick emits nothing but keeps the book current" do
      values = all_values(spec(), linear_impact_ticks())

      # The quote at index 6 sits between two real values.
      assert Enum.at(values, 6) == :warming_up
      assert %Decimal{} = Enum.at(values, 5)
      assert %Decimal{} = Enum.at(values, 7)
    end

    # Same regression as :signed_volume's -- a live trade message can
    # carry volume: nil, which crashed Decimal.mult/2 before trade_size/1.
    test "an explicit nil volume does not crash" do
      ticks = [
        quote_at(0, 99.99, 100.01),
        %{at: DateTime.add(@now, 1, :second), value: 100.01, volume: nil},
        quote_at(2, 100.09, 100.11),
        %{at: DateTime.add(@now, 3, :second), value: 100.11, volume: nil}
      ]

      {_state, value} = run(spec(), ticks)

      assert value == :warming_up or match?(%Decimal{}, value)
    end

    test "an incomplete book is warming up even with a trade" do
      ticks = [
        %{at: @now, value: nil, bid: 99.99},
        trade_at(1, 100.01, 100)
      ]

      {_state, value} = run(spec(), ticks)

      assert value == :warming_up
    end
  end

  describe "classifier reuse" do
    test "shares :signed_volume's classifier, so the two cannot disagree" do
      assert_raise ArgumentError, ~r/unknown classifier/, fn ->
        Compute.init(%Spec{kind: :kyle_lambda, params: %{"classifier" => "bogus"}})
      end
    end

    test "tick_rule works without relying on the quote to sign trades" do
      ticks = [
        quote_at(0, 99.99, 100.01),
        trade_at(1, 100.00, 100),
        quote_at(2, 100.09, 100.11),
        trade_at(3, 100.10, 200),
        quote_at(4, 100.29, 100.31),
        trade_at(5, 100.30, 300)
      ]

      {_state, value} = run(spec(%{"classifier" => "tick_rule"}), ticks)

      assert %Decimal{} = value
    end
  end

  describe "spec wiring" do
    test "kyle_lambda is a base kind and enumerated" do
      assert Spec.base_kind?(:kyle_lambda)
      refute Spec.single_parent_kind?(:kyle_lambda)
      refute Spec.dual_parent_kind?(:kyle_lambda)
      assert :kyle_lambda in Spec.kinds()
    end
  end
end
