defmodule TradingCore.Signal.MovingAverageSessionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias TradingCore.Signal.{Compute, Spec}
  alias TradingCore.{Session, Signals}

  # Friday 2026-10-09, EDT: 09:00 ET = 13:00 UTC. A 5m window at 60s: n = 5.
  @opts [window_ms: 300_000, sample_interval_ms: 60_000]
  @reset [session_reset: &Session.us_equities/1]

  defp et(hh, mm),
    do:
      DateTime.new!(~D[2026-10-09], Time.new!(hh, mm, 0), "America/New_York")
      |> DateTime.shift_zone!("Etc/UTC")

  # Pre-open TICK at 500 every minute 09:00-09:29, then 10 from 09:30.
  defp open_series do
    pre = for m <- 0..29, do: {et(9, m), Decimal.new(500)}
    post = for m <- 30..40, do: {et(9, m), Decimal.new(10)}
    pre ++ post
  end

  defp fold(points, opts) do
    {_state, results} =
      Enum.reduce(points, {Signals.moving_average_new(), []}, fn {t, v}, {st, acc} ->
        {st, r} = Signals.moving_average(st, v, t, opts)
        {st, [{t, r} | acc]}
      end)

    Enum.reverse(results)
  end

  defp at_time(results, t), do: results |> Enum.find(fn {at, _} -> at == t end) |> elem(1)

  test "unset: identical to today's results (session_reset: nil is a no-op)" do
    assert fold(open_series(), @opts) == fold(open_series(), @opts ++ [session_reset: nil])
  end

  test "without a reset, pre-open TICK pollutes the open (the reported bug)" do
    results = fold(open_series(), @opts)
    # 09:30's window is 09:26..09:30: four 500s and one 10
    assert Decimal.equal?(at_time(results, et(9, 30)), 402)
  end

  test "with us_equities/1: warms up from 09:30 and averages only post-open values" do
    results = fold(open_series(), @opts ++ @reset)

    for m <- 30..33, do: assert(at_time(results, et(9, m)) == nil, "09:#{m}")
    for m <- 34..40, do: assert(Decimal.equal?(at_time(results, et(9, m)), 10), "09:#{m}")
  end

  test "pre-open ticks still form their own (prior) session before 09:30" do
    # 09:04 is the 5th pre-open bucket: warm, all 500s.
    results = fold(open_series(), @opts ++ @reset)
    assert Decimal.equal?(at_time(results, et(9, 4)), 500)
  end

  test "batch equals incremental with the reset set" do
    assert Signals.moving_average_series(open_series(), @opts ++ @reset) ==
             fold(open_series(), @opts ++ @reset)
  end

  property "batch equals incremental with the reset, across random times around the open" do
    check all(
            offsets <- list_of(integer(0..150), min_length: 1, max_length: 60),
            values <- list_of(integer(-800..800), length: length(offsets))
          ) do
      # random minutes from 08:45 to ~11:15 ET, chronological
      points =
        offsets
        |> Enum.sort()
        |> Enum.zip_with(values, fn m, v -> {DateTime.add(et(8, 45), m * 60), Decimal.new(v)} end)
        |> Enum.uniq_by(&elem(&1, 0))

      assert Signals.moving_average_series(points, @opts ++ @reset) ==
               fold(points, @opts ++ @reset)
    end
  end

  describe "Compute" do
    defp spec(params),
      do: %Spec{
        kind: :moving_average,
        window_ms: 300_000,
        params: Map.merge(%{"sample_interval_ms" => 60_000}, params)
      }

    defp step_all(spec, points) do
      {:ok, st} = Compute.init(spec)

      {_st, out} =
        Enum.reduce(points, {st, []}, fn {t, v}, {st, acc} ->
          {st, o} = Compute.step(spec, st, %{at: t, value: v})
          {st, [{t, o} | acc]}
        end)

      Enum.reverse(out)
    end

    test "params[\"session_reset\"] restarts the window at 09:30" do
      out = step_all(spec(%{"session_reset" => &Session.us_equities/1}), open_series())

      assert at_time(out, et(9, 30)) == :warming_up
      assert Decimal.equal?(at_time(out, et(9, 34)), 10)

      unset = step_all(spec(%{}), open_series())
      assert Decimal.equal?(at_time(unset, et(9, 30)), 402)
    end

    property "fold equals replay with session_reset set" do
      check all(
              offsets <- list_of(integer(0..150), min_length: 2, max_length: 50),
              values <- list_of(integer(-800..800), length: length(offsets)),
              max_runs: 60
            ) do
        ticks =
          offsets
          |> Enum.sort()
          |> Enum.uniq()
          |> Enum.zip_with(values, fn m, v ->
            %{at: DateTime.add(et(8, 45), m * 60), value: Decimal.new(v)}
          end)

        s = spec(%{"session_reset" => &Session.us_equities/1})
        {:ok, st} = Compute.init(s)

        {_st, folded} =
          Enum.reduce(ticks, {st, []}, fn tick, {st, acc} ->
            {st, o} = Compute.step(s, st, tick)
            {st, [o | acc]}
          end)

        wrapped = %{s | parent: %Spec{kind: :plain}}
        assert Enum.reverse(folded) == Compute.replay(wrapped, ticks, only: wrapped)
      end
    end
  end
end
