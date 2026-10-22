defmodule TradingCore.Signal.ComputeBarKindsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias TradingCore.Signal.{Compute, Spec}
  alias TradingCore.Signals.BarIndicators, as: BI

  @t0 ~U[2026-10-21 14:00:00Z]
  defp at(sec), do: DateTime.add(@t0, sec)

  defp spec(kind, params, window_ms \\ nil),
    do: %Spec{kind: kind, symbol: "SPY", params: params, window_ms: window_ms}

  defp run(spec, ticks) do
    {:ok, st} = Compute.init(spec)

    {_st, out} =
      Enum.reduce(ticks, {st, []}, fn t, {st, acc} ->
        {st, o} = Compute.step(spec, st, t)
        {st, [o | acc]}
      end)

    Enum.reverse(out)
  end

  defp dec(x), do: x |> Decimal.from_float() |> Decimal.round(8)

  # Several ticks per minute over `minutes` minutes, a wandering price.
  defp minute_ticks(minutes, start_sec \\ 0) do
    for m <- 0..(minutes - 1), s <- [0, 15, 40, 55] do
      v = 100 + 3 * :math.sin(m / 3) + (s - 30) / 60 + rem(m * 7 + s, 5) * 0.1
      %{at: at(start_sec + m * 60 + s), value: Float.round(v, 4)}
    end
  end

  # The bars the ticks form, built directly.
  defp bars_of(ticks) do
    ticks
    |> Enum.chunk_by(&div(DateTime.to_unix(&1.at), 60))
    |> Enum.map(fn ts ->
      vs = Enum.map(ts, & &1.value)
      %{open: hd(vs), high: Enum.max(vs), low: Enum.min(vs), close: List.last(vs)}
    end)
  end

  describe ":atr / :adx" do
    test "atr from ticks equals the bar-built ATR, emitted only on bar closes" do
      ticks = minute_ticks(25)
      s = spec(:atr, %{"period" => 5})
      out = run(s, ticks)

      # bars 1..24 close (the 25th is still open); bar k closes on the
      # first tick of minute k, i.e. tick index 4k
      bars = ticks |> bars_of() |> Enum.take(24)

      expected =
        bars |> Enum.scan(BI.atr_new(), &BI.atr_push(&2, &1, 5)) |> Enum.map(&BI.atr_value/1)

      closes = for k <- 1..24, do: Enum.at(out, 4 * k)

      Enum.zip(closes, expected)
      |> Enum.each(fn
        {:warming_up, nil} -> :ok
        {got, want} -> assert got == dec(want)
      end)

      # between closes the value repeats
      assert Enum.at(out, 4 * 10 + 1) == Enum.at(out, 4 * 10)
      assert Enum.take(out, 4 * 5) |> Enum.all?(&(&1 == :warming_up))
    end

    test "bar_closed is true exactly on the step that closes a bar" do
      s = spec(:atr, %{"period" => 2})
      {:ok, st} = Compute.init(s)

      flags =
        Enum.map_reduce([{0, 1.0}, {30, 2.0}, {60, 1.5}, {61, 1.6}, {125, 1.7}], st, fn {sec, v},
                                                                                        st ->
          {st, _} = Compute.step(s, st, %{at: at(sec), value: v})
          {st.bar_closed, st}
        end)
        |> elem(0)

      assert flags == [false, false, true, false, true]
    end

    test "atr_pct and the adx outputs" do
      ticks = minute_ticks(40)
      bars = ticks |> bars_of() |> Enum.take(39)

      atr_st = Enum.reduce(bars, BI.atr_new(), &BI.atr_push(&2, &1, 14))

      assert List.last(run(spec(:atr, %{"output" => "atr_pct"}), ticks)) ==
               dec(BI.atr_pct_value(atr_st))

      adx_st = Enum.reduce(bars, BI.adx_new(), &BI.adx_push(&2, &1, 14))
      {pd, md} = BI.di(adx_st)
      assert List.last(run(spec(:adx, %{}), ticks)) == dec(BI.adx_value(adx_st))
      assert List.last(run(spec(:adx, %{"output" => "plus_di"}), ticks)) == dec(pd)
      assert List.last(run(spec(:adx, %{"output" => "minus_di"}), ticks)) == dec(md)
    end

    test "bar_interval_ms changes the bar size" do
      ticks = minute_ticks(30)

      five_min =
        ticks
        |> Enum.chunk_by(&div(DateTime.to_unix(&1.at), 300))
        |> Enum.map(fn ts ->
          vs = Enum.map(ts, & &1.value)
          %{open: hd(vs), high: Enum.max(vs), low: Enum.min(vs), close: List.last(vs)}
        end)

      st = five_min |> Enum.take(5) |> Enum.reduce(BI.atr_new(), &BI.atr_push(&2, &1, 3))

      assert List.last(run(spec(:atr, %{"period" => 3, "bar_interval_ms" => 300_000}), ticks)) ==
               dec(BI.atr_value(st))
    end

    test "session_reset clears bars and smoothing; an unbroken session does not reset" do
      day = &DateTime.to_date/1
      s = spec(:atr, %{"period" => 3, "session_reset" => day})
      today = minute_ticks(10)
      tomorrow = minute_ticks(10, 86_400)

      out = run(s, today ++ tomorrow)
      # ready again only after 3 new bars close in the new session
      next = Enum.drop(out, length(today))
      assert Enum.take(next, 4 * 3) |> Enum.all?(&(&1 == :warming_up))
      assert %Decimal{} = Enum.at(next, 4 * 3)
      # and equals a fresh run over tomorrow alone
      assert next == run(s, tomorrow)

      # without a day change the same ticks never reset
      same_day = minute_ticks(10, 600)
      unbroken = run(s, today ++ same_day) |> Enum.drop(length(today))
      assert Enum.all?(unbroken, &match?(%Decimal{}, &1))
    end

    test "invalid params raise at init" do
      for {kind, bad} <- [
            {:atr, %{"period" => 0}},
            {:atr, %{"output" => "adx"}},
            {:adx, %{"bar_interval_ms" => 0}},
            {:adx, %{"output" => "atr"}},
            {:adx, %{"session_reset" => "daily"}}
          ] do
        assert_raise ArgumentError, fn -> Compute.init(spec(kind, bad)) end
      end
    end
  end

  describe ":ibs" do
    test "(last - session low) / (session high - session low)" do
      out =
        run(spec(:ibs, %{}), [
          %{at: at(0), value: 10.0},
          %{at: at(1), value: 12.0},
          %{at: at(2), value: 8.0},
          %{at: at(3), value: 11.0}
        ])

      assert out == [:warming_up, dec(1.0), dec(0.0), dec(0.75)]
    end

    test "no number (not 0) while high == low" do
      assert run(spec(:ibs, %{}), [%{at: at(0), value: 5.0}, %{at: at(1), value: 5.0}]) ==
               [:warming_up, :warming_up]
    end

    test "session_reset starts a new high and low; an unbroken session keeps them" do
      s = spec(:ibs, %{"session_reset" => &DateTime.to_date/1})
      day1 = [%{at: at(0), value: 10.0}, %{at: at(1), value: 20.0}]

      assert run(s, day1 ++ [%{at: at(86_400), value: 15.0}]) |> List.last() == :warming_up
      assert run(s, day1 ++ [%{at: at(60), value: 15.0}]) |> List.last() == dec(0.5)
    end
  end

  describe ":bollinger_bandwidth" do
    # One tick per minute, sampled every minute, 5-minute window: the
    # window holds the samples at or after now - 5m, i.e. the last 6.
    defp bb(params) do
      spec(:bollinger_bandwidth, Map.merge(%{"sample_interval_ms" => 60_000}, params), 300_000)
    end

    defp bb_ticks(values),
      do: values |> Enum.with_index() |> Enum.map(fn {v, i} -> %{at: at(i * 60), value: v} end)

    defp mean_sd(xs) do
      n = length(xs)
      mean = Enum.sum(xs) / n
      {mean, :math.sqrt(Enum.sum(Enum.map(xs, &((&1 - mean) ** 2))) / (n - 1))}
    end

    test "bandwidth = 2k·sd/mean·100 and percent_b, with the sample sd" do
      values = [100.0, 101.0, 99.5, 102.0, 100.5, 103.0, 101.5, 104.0]
      ticks = bb_ticks(values)
      {mean, sd} = mean_sd(Enum.take(values, -6))

      assert List.last(run(bb(%{}), ticks)) == dec(2 * 2 * sd / mean * 100)
      assert List.last(run(bb(%{"k" => 1.5}), ticks)) == dec(2 * 1.5 * sd / mean * 100)

      lower = mean - 2 * sd

      assert List.last(run(bb(%{"output" => "percent_b"}), ticks)) ==
               dec((104.0 - lower) / (4 * sd))
    end

    test "warms up until the window is covered" do
      out = run(bb(%{}), bb_ticks([100.0, 101.0, 99.0, 102.0, 100.0, 101.0]))
      # minute 4 is the first with a span of window - one interval
      assert Enum.take(out, 4) |> Enum.all?(&(&1 == :warming_up))
      assert %Decimal{} = Enum.at(out, 4)
    end

    test "percent_b has no number on a flat window" do
      assert run(bb(%{"output" => "percent_b"}), bb_ticks(List.duplicate(50.0, 7))) |> List.last() ==
               :warming_up
    end

    test "session_reset clears the window" do
      s = bb(%{"session_reset" => &DateTime.to_date/1})
      day1 = bb_ticks([100.0, 101.0, 99.0, 102.0, 100.0, 101.0])
      assert run(s, day1 ++ [%{at: at(86_400), value: 100.0}]) |> List.last() == :warming_up
    end

    test "invalid params raise at init" do
      assert_raise ArgumentError, fn -> Compute.init(spec(:bollinger_bandwidth, %{})) end
      assert_raise ArgumentError, fn -> Compute.init(bb(%{"k" => 0})) end
      assert_raise ArgumentError, fn -> Compute.init(bb(%{"output" => "squeeze"})) end
    end
  end

  property "replay/3 equals folding step/2 for every new kind" do
    check all(
            moves <- list_of(float(min: -1.0, max: 1.0), min_length: 2, max_length: 80),
            gaps <- list_of(integer(1..50), length: length(moves)),
            kind <- member_of([:atr, :adx, :ibs, :bollinger_bandwidth])
          ) do
      ticks =
        Enum.zip(Enum.scan(moves, 100.0, &(&1 + &2)), Enum.scan(gaps, &(&1 + &2)))
        |> Enum.map(fn {v, sec} -> %{at: at(sec), value: v} end)

      s =
        case kind do
          :bollinger_bandwidth -> spec(kind, %{"sample_interval_ms" => 30_000}, 180_000)
          :ibs -> spec(kind, %{})
          _ -> spec(kind, %{"period" => 3})
        end

      assert run(s, ticks) == Compute.replay(s, ticks, only: s)
    end
  end
end
