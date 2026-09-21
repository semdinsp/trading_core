defmodule TradingCore.Signal.TwoScaleRvTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias TradingCore.Signal.{Compute, Spec}
  alias TradingCore.Signals

  @now ~U[2026-09-21 14:00:00Z]

  defp run(params, prices) do
    spec = %Spec{kind: :two_scale_rv, symbol: "SPY", params: params}
    {:ok, state} = Compute.init(spec)

    prices
    |> Enum.with_index()
    |> Enum.reduce({state, :warming_up}, fn {price, i}, {acc, _} ->
      Compute.step(spec, acc, %{at: DateTime.add(@now, i, :second), value: price})
    end)
  end

  # A random walk plus iid multiplicative noise -- the exact situation
  # the estimator exists for. Seeded, so the assertions are stable.
  defp noisy_walk(n, noise_bps) do
    :rand.seed(:exsss, {1, 2, 3})
    true_prices = Enum.scan(1..n, 100.0, fn _, p -> p * :math.exp(0.0002 * :rand.normal()) end)
    noisy = Enum.map(true_prices, fn p -> p * (1 + noise_bps * :rand.normal()) end)
    {true_prices, noisy}
  end

  describe "Signals.two_scale_rv/2 -- the estimator itself" do
    test "recovers true variance from a noisy series that defeats naive RV" do
      {true_prices, noisy} = noisy_walk(400, 0.0004)

      true_rv = Signals.naive_rv(true_prices)
      naive = Signals.naive_rv(noisy)
      tsrv = Signals.two_scale_rv(noisy, 5)

      # Naive RV is dominated by the noise -- an order of magnitude high.
      assert naive > true_rv * 5, "naive RV should be badly inflated by noise"

      # The corrected estimate lands close to truth.
      assert_in_delta tsrv, true_rv, true_rv * 0.25
    end

    test "is dramatically closer to truth than naive RV" do
      {true_prices, noisy} = noisy_walk(400, 0.0004)

      true_rv = Signals.naive_rv(true_prices)
      naive_err = abs(Signals.naive_rv(noisy) - true_rv)
      tsrv_err = abs(Signals.two_scale_rv(noisy, 5) - true_rv)

      assert tsrv_err < naive_err / 10
    end

    test "nil when the slow scale cannot be estimated" do
      prices = Enum.map(1..5, &(100.0 + &1))

      # k + 1 = 11 returns needed for k = 10; only 4 available.
      assert Signals.two_scale_rv(prices, 10) == nil
    end

    test "nil on an empty or single-price series" do
      assert Signals.two_scale_rv([], 5) == nil
      assert Signals.two_scale_rv([100.0], 5) == nil
    end

    test "a flat series has zero variance" do
      assert Signals.two_scale_rv(List.duplicate(100.0, 50), 5) == 0.0
    end

    test "never returns a negative variance" do
      # The correction can overshoot on a short or quiet window. A
      # negative variance is an estimator failure, not a small variance,
      # and callers take square roots of this.
      {_true, noisy} = noisy_walk(40, 0.002)

      assert Signals.two_scale_rv(noisy, 10) >= 0.0
    end

    test "accepts Decimal prices as well as floats" do
      {_true, noisy} = noisy_walk(100, 0.0004)
      decimals = Enum.map(noisy, &Decimal.from_float/1)

      assert_in_delta Signals.two_scale_rv(decimals, 5),
                      Signals.two_scale_rv(noisy, 5),
                      1.0e-12
    end

    property "never negative, for any positive price series" do
      check all(
              prices <- list_of(float(min: 1.0, max: 1000.0), min_length: 12, max_length: 60),
              k <- integer(2..5)
            ) do
        case Signals.two_scale_rv(prices, k) do
          nil -> :ok
          value -> assert value >= 0.0
        end
      end
    end
  end

  describe "Signals.naive_rv/1" do
    test "sums squared log returns" do
      # log(110/100)^2 + log(121/110)^2, both = log(1.1)^2
      expected = 2 * :math.pow(:math.log(1.1), 2)

      assert_in_delta Signals.naive_rv([100.0, 110.0, 121.0]), expected, 1.0e-12
    end

    test "nil below two prices" do
      assert Signals.naive_rv([]) == nil
      assert Signals.naive_rv([100.0]) == nil
    end
  end

  describe ":two_scale_rv kind" do
    test "emits the corrected variance through step/2" do
      {true_prices, noisy} = noisy_walk(400, 0.0004)
      true_rv = Signals.naive_rv(true_prices)

      {_state, value} = run(%{"subsample_k" => 5}, noisy)

      assert is_float(value)
      assert_in_delta value, true_rv, true_rv * 0.25
    end

    test "warms up until the slow scale has enough samples" do
      {_state, value} = run(%{"subsample_k" => 10}, Enum.map(1..5, &(100.0 + &1)))

      assert value == :warming_up
    end

    test "tick_count and time modes give materially different answers" do
      # The reason the mode is explicit rather than defaulted: a fixed
      # tick count spans seconds on a liquid name and minutes on a thin
      # one, so these are different estimators, not two spellings of one.
      {_true, noisy} = noisy_walk(400, 0.0004)

      {_s, by_ticks} = run(%{"subsample_mode" => "tick_count", "subsample_k" => 5}, noisy)
      {_s, by_time} = run(%{"subsample_mode" => "time", "subsample_ms" => 5_000}, noisy)

      assert is_float(by_ticks)
      assert is_float(by_time)
      refute_in_delta by_ticks, by_time, by_ticks * 0.1
    end

    test "an unrecognised subsample_mode raises at init, not mid-stream" do
      # Failing where the spec is built beats silently warming up forever
      # inside a live loop.
      assert_raise ArgumentError, ~r/unknown subsample_mode/, fn ->
        Compute.init(%Spec{kind: :two_scale_rv, params: %{"subsample_mode" => "bogus"}})
      end
    end

    test "window_ms drops prices older than the window" do
      # window_ms is a Spec FIELD, not a param -- window_opts/1 reads it
      # off the struct, so passing it in params would be silently ignored.
      {_true, noisy} = noisy_walk(400, 0.0004)

      spec = %Spec{
        kind: :two_scale_rv,
        symbol: "SPY",
        window_ms: 60_000,
        params: %{"subsample_k" => 5}
      }

      {:ok, state} = Compute.init(spec)

      {state, _value} =
        noisy
        |> Enum.with_index()
        |> Enum.reduce({state, :warming_up}, fn {price, i}, {acc, _} ->
          Compute.step(spec, acc, %{at: DateTime.add(@now, i, :second), value: price})
        end)

      # One tick per second, 60s window: far fewer than 400 retained.
      assert length(state.prices) <= 61
    end

    test "max_history_samples caps retained prices" do
      {_true, noisy} = noisy_walk(400, 0.0004)

      {state, _value} = run(%{"subsample_k" => 5, "max_history_samples" => 50}, noisy)

      assert length(state.prices) == 50
    end
  end

  describe "spec wiring" do
    test "two_scale_rv is a base kind and enumerated" do
      assert Spec.base_kind?(:two_scale_rv)
      refute Spec.single_parent_kind?(:two_scale_rv)
      refute Spec.dual_parent_kind?(:two_scale_rv)
      assert :two_scale_rv in Spec.kinds()
    end
  end
end
