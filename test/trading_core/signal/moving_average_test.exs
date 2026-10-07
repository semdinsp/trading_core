defmodule TradingCore.Signal.MovingAverageTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias TradingCore.Signal.{Compute, Spec}
  alias TradingCore.Signals

  @t0 ~U[2026-10-07 13:30:00Z]

  defp d(v) when is_integer(v), do: Decimal.new(v)
  defp d(v) when is_binary(v), do: Decimal.new(v)

  defp at(seconds), do: DateTime.add(@t0, seconds)

  # A 60s window sampled every 10s: n = 6 buckets.
  @opts [window_ms: 60_000, sample_interval_ms: 10_000]

  defp fold(points, opts \\ @opts) do
    {_state, results} =
      Enum.reduce(points, {Signals.moving_average_new(), []}, fn {t, v}, {state, acc} ->
        {state, result} = Signals.moving_average(state, v, t, opts)
        {state, [{t, result} | acc]}
      end)

    Enum.reverse(results)
  end

  defp last_value(points, opts \\ @opts), do: points |> fold(opts) |> List.last() |> elem(1)

  describe "Signals.moving_average/4" do
    test "warming up until the held values cover the whole window" do
      # Buckets 0..5 make a full 6-bucket window only at the 6th bucket.
      points = for i <- 0..5, do: {at(i * 10), d(i)}
      results = fold(points)

      assert Enum.take(results, 5) |> Enum.all?(fn {_t, r} -> r == nil end)
      # mean of 0..5 = 2.5
      assert Decimal.equal?(elem(List.last(results), 1), "2.5")
    end

    test "time-weighted: a value held for longer counts for longer" do
      # 100 for buckets 0-4 (one tick, then nothing), 400 from bucket 5:
      # window of buckets 0..5 = (5*100 + 400) / 6 = 150.
      assert Decimal.equal?(last_value([{at(0), d(100)}, {at(50), d(400)}]), 150)

      # The same values ticked every second give the same mean.
      dense = for s <- 0..49, do: {at(s), d(100)}
      assert Decimal.equal?(last_value(dense ++ [{at(50), d(400)}]), 150)
    end

    test "independent of tick rate at a fixed interval" do
      steps = [{0, 10}, {20, 30}, {35, -5}, {55, 12}, {80, 7}]

      at_rate = fn per_second ->
        for {start, value} <- steps,
            k <- 0..(per_second * 5 - 1),
            do: {DateTime.add(at(start), div(k * 1000, per_second), :millisecond), d(value)}
      end

      assert last_value(at_rate.(1)) == last_value(at_rate.(10))

      assert last_value(at_rate.(1)) ==
               last_value(Enum.map(steps, fn {s, v} -> {at(s), d(v)} end))
    end

    test "the last value in a bucket is its sample" do
      # Bucket 5 sees 7, then 9: its sample is 9.
      points = [{at(0), d(0)}, {at(51), d(7)}, {at(58), d(9)}]
      # (5 * 0 + 9) / 6 = 1.5
      assert Decimal.equal?(last_value(points), "1.5")
    end

    test "no look-ahead: a later tick never changes an earlier result" do
      base = for i <- 0..8, do: {at(i * 10), d(i * 3)}
      results = fold(base)
      with_future = fold(base ++ [{at(90), d(1000)}, {at(100), d(-1000)}])

      assert Enum.take(with_future, length(results)) == results
    end

    test "a gap of a full window (overnight) resets: warming up again, then a fresh mean" do
      day1 = for i <- 0..9, do: {at(i * 10), d(50)}
      # next session 17.5h later
      next = :timer.hours(17) |> div(1000) |> Kernel.+(1800)
      day2 = for i <- 0..5, do: {at(next + i * 10), d(i)}

      results = fold(day1 ++ day2)
      {_day1, day2_results} = Enum.split(results, 10)

      assert Enum.take(day2_results, 5) |> Enum.all?(fn {_t, r} -> r == nil end)
      # day 1's 50s are not held overnight: mean of 0..5 = 2.5
      assert Decimal.equal?(elem(List.last(day2_results), 1), "2.5")
    end

    test "a shorter gap is held across: the feed went quiet, the value stood" do
      # Ticks at 0 and 40s: buckets 0-3 hold 10, bucket 4 is 70, and at 50s
      # bucket 5 holds 70: (4*10 + 2*70) / 6 = 30.
      points = [{at(0), d(10)}, {at(40), d(70)}, {at(50), d(70)}]
      assert Decimal.equal?(last_value(points), 30)
    end

    test "results are rounded to :precision" do
      points = for i <- 0..5, do: {at(i * 10), d(if(i == 5, do: 1, else: 0))}
      # 1/6
      assert last_value(points) == Decimal.new("0.16666667")
    end

    test "state stays small: one run per value change, not per tick" do
      {state, _} =
        Enum.reduce(0..9_999, {Signals.moving_average_new(), nil}, fn s, {state, _} ->
          Signals.moving_average(state, d(5), at(s), window_ms: 900_000)
        end)

      assert length(state.runs) == 1
    end
  end

  describe "batch equivalence" do
    test "moving_average_series/2 equals folding moving_average/4 on a fixed series" do
      points =
        [
          {0, 5},
          {3, 6},
          {14, 2},
          {15, 2},
          {44, 9},
          {52, -1},
          {58, 4},
          {71, 4},
          {130, 8},
          {200, 1},
          {205, 3},
          {211, 3},
          {219, 0},
          {231, 6},
          {250, 7},
          {260, 2}
        ]
        |> Enum.map(fn {s, v} -> {at(s), d(v)} end)

      assert Signals.moving_average_series(points, @opts) == fold(points)
    end

    property "batch and incremental agree on random series" do
      check all(
              gaps <- list_of(integer(0..40), min_length: 1, max_length: 60),
              values <- list_of(integer(-500..500), length: length(gaps)),
              max_runs: 150
            ) do
        times = Enum.scan(gaps, &(&1 + &2))
        points = Enum.zip_with(times, values, fn s, v -> {at(s), d(v)} end)

        assert Signals.moving_average_series(points, @opts) == fold(points)
      end
    end
  end

  describe "Compute :moving_average" do
    test "steps like the Signals function, with the spec's window and interval" do
      spec = %Spec{
        kind: :moving_average,
        parent: %Spec{kind: :plain, symbol: "NYSE-TICK", source: "ibkr"},
        window_ms: 60_000,
        params: %{"sample_interval_ms" => 10_000}
      }

      {:ok, state} = Compute.init(spec)
      points = for i <- 0..7, do: {at(i * 10), d(i * 100)}

      {_state, emitted} =
        Enum.reduce(points, {state, []}, fn {t, v}, {st, acc} ->
          {st, out} = Compute.step(spec, st, %{at: t, value: v})
          {st, [out | acc]}
        end)

      expected = points |> fold() |> Enum.map(fn {_t, r} -> r || :warming_up end)
      assert Enum.reverse(emitted) == expected
      assert Enum.take(Enum.reverse(emitted), 5) |> Enum.all?(&(&1 == :warming_up))
    end

    test "is a single-parent kind" do
      assert Spec.single_parent_kind?(:moving_average)
    end
  end
end
