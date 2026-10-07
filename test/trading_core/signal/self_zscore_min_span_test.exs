defmodule TradingCore.Signal.SelfZscoreMinSpanTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias TradingCore.Signal.{Compute, Spec}
  alias TradingCore.{Signals, WelfordAcc}

  @t0 ~U[2026-10-07 13:30:00Z]

  defp at(seconds), do: DateTime.add(@t0, seconds)

  # A varying series, one sample a minute.
  defp series(from_s, n),
    do: for(i <- 0..(n - 1), do: {at(from_s + i * 60), Decimal.new(rem(i * 37, 11) - 5)})

  defp fold(points, opts) do
    {_h, _w, out} =
      Enum.reduce(points, {[], WelfordAcc.new(), []}, fn {t, v}, {h, w, acc} ->
        {h, w, z} = Signals.self_zscore(h, w, v, t, opts)
        {h, w, [z | acc]}
      end)

    Enum.reverse(out)
  end

  @window [window_ms: :timer.minutes(30), sample_interval_ms: 60_000]

  test "unset: emits from the second varying sample, exactly as before" do
    out = fold(series(0, 20), @window)

    assert Enum.at(out, 0) == nil
    assert Enum.at(out, 1) != nil
    assert out == fold(series(0, 20), @window ++ [min_span_ms: nil])
  end

  test "set: nil until the samples span min_span_ms, then the same values as unset" do
    unset = fold(series(0, 20), @window)
    gated = fold(series(0, 20), @window ++ [min_span_ms: :timer.minutes(10)])

    # samples at 0..9 min span less than 10 min; the 11th (at 10 min) reaches it
    assert Enum.take(gated, 10) |> Enum.all?(&is_nil/1)
    assert Enum.drop(gated, 10) == Enum.drop(unset, 10)
  end

  test "overnight gap longer than the window: the span restarts and the session warms up again" do
    opts = @window ++ [min_span_ms: :timer.minutes(10)]
    next_session = div(:timer.hours(17), 1000) + 1800
    out = fold(series(0, 20) ++ series(next_session, 15), opts)
    {day1, day2} = Enum.split(out, 20)

    assert Enum.at(day1, 19) != nil
    assert Enum.take(day2, 10) |> Enum.all?(&is_nil/1)
    assert Enum.at(day2, 10) != nil
  end

  test "Compute: params[\"min_span_ms\"] gates :self_zscore; unset does not" do
    base = %Spec{
      kind: :self_zscore,
      window_ms: :timer.minutes(30),
      params: %{"sample_interval_ms" => 60_000}
    }

    gated = %{base | params: Map.put(base.params, "min_span_ms", :timer.minutes(10))}

    run = fn spec ->
      {:ok, st} = Compute.init(spec)

      {_st, out} =
        Enum.reduce(series(0, 15), {st, []}, fn {t, v}, {st, acc} ->
          {st, o} = Compute.step(spec, st, %{at: t, value: v})
          {st, [o | acc]}
        end)

      Enum.reverse(out)
    end

    assert Enum.at(run.(base), 1) != :warming_up
    assert Enum.take(run.(gated), 10) |> Enum.all?(&(&1 == :warming_up))
    assert Enum.drop(run.(gated), 10) == Enum.drop(run.(base), 10)
  end

  property "Compute: folding step equals replay with min_span_ms set" do
    check all(
            gaps <- list_of(integer(1..120), min_length: 2, max_length: 80),
            values <- list_of(integer(-50..50), length: length(gaps)),
            max_runs: 100
          ) do
      ticks =
        gaps
        |> Enum.scan(&(&1 + &2))
        |> Enum.zip_with(values, fn s, v -> %{at: at(s), value: Decimal.new(v)} end)

      spec = %Spec{
        kind: :self_zscore,
        window_ms: :timer.minutes(30),
        params: %{"min_span_ms" => :timer.minutes(5)}
      }

      {:ok, st} = Compute.init(spec)

      {_st, folded} =
        Enum.reduce(ticks, {st, []}, fn tick, {st, acc} ->
          {st, o} = Compute.step(spec, st, tick)
          {st, [o | acc]}
        end)

      wrapped = %{spec | parent: %Spec{kind: :plain}}
      assert Enum.reverse(folded) == Compute.replay(wrapped, ticks, only: wrapped)
    end
  end
end
