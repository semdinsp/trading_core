defmodule TradingCore.Signal.TickWindowTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias TradingCore.Signal.{Compute, Spec, TickWindow}
  alias TradingCore.Signals

  @now ~U[2026-09-21 14:00:00Z]

  describe "running sum" do
    property "equals re-summing the points still in the window" do
      check all(
              gaps <- list_of(integer(0..2_000), min_length: 1, max_length: 200),
              values <- list_of(integer(-500..500), length: length(gaps)),
              window_ms <- integer(1..5_000)
            ) do
        stamps = Enum.scan(gaps, 0, &(&1 + &2))
        points = Enum.zip(stamps, values)

        Enum.reduce(points, {TickWindow.sum_new(), []}, fn {ms, v}, {w, seen} ->
          at = DateTime.add(@now, ms, :millisecond)
          {w, 0} = TickWindow.sum_push(w, at, Decimal.new(v), at, window_ms, 1_000_000)
          seen = [{ms, v} | seen]

          expected =
            seen
            |> Enum.filter(fn {t, _} -> t >= ms - window_ms end)
            |> Enum.map(&elem(&1, 1))
            |> Enum.sum()

          assert Decimal.equal?(TickWindow.sum_total(w), Decimal.new(expected))
          {w, seen}
        end)
      end
    end

    test "a binding cap drops the oldest points, subtracts them, and says how many" do
      {w, dropped} =
        Enum.reduce(1..10, {TickWindow.sum_new(), 0}, fn i, {w, d} ->
          at = DateTime.add(@now, i, :millisecond)
          {w, new} = TickWindow.sum_push(w, at, Decimal.new(i), at, 60_000, 4)
          {w, d + new}
        end)

      assert dropped == 6
      assert TickWindow.sum_size(w) == 4
      assert Decimal.equal?(TickWindow.sum_total(w), Decimal.new(7 + 8 + 9 + 10))
    end
  end

  describe "two-scale realized variance" do
    property "matches the batch estimator over the same window" do
      check all(
              gaps <- list_of(integer(1..400), min_length: 2, max_length: 300),
              moves <- list_of(float(min: -0.002, max: 0.002), length: length(gaps)),
              window_ms <- integer(500..20_000),
              k <- integer(2..6)
            ) do
        stamps = Enum.scan(gaps, 0, &(&1 + &2))
        prices = Enum.scan(moves, 100.0, fn m, p -> p * :math.exp(m) end)

        Enum.reduce(Enum.zip(stamps, prices), {TickWindow.rv_new(k), []}, fn {ms, p},
                                                                             {rv, seen} ->
          at = DateTime.add(@now, ms, :millisecond)
          {rv, 0} = TickWindow.rv_push(rv, at, p, at, window_ms, 1_000_000)
          seen = [{ms, p} | seen]

          window =
            seen
            |> Enum.filter(fn {t, _} -> t >= ms - window_ms end)
            |> Enum.reverse()
            |> Enum.map(&elem(&1, 1))

          case {TickWindow.rv_value(rv), Signals.two_scale_rv(window, k)} do
            {nil, nil} ->
              :ok

            {a, b} when is_float(a) and is_float(b) ->
              assert_in_delta a, b, 1.0e-12 + abs(b) * 1.0e-9
          end

          {rv, seen}
        end)
      end
    end
  end

  # ~100 ticks/sec, like SPY quotes: 10ms spacing.
  defp busy_ticks(n, fun),
    do: Enum.map(0..(n - 1), fn i -> fun.(i, DateTime.add(@now, i * 10, :millisecond)) end)

  defp fold(spec, ticks) do
    {:ok, state} = Compute.init(spec)
    Enum.reduce(ticks, {state, :warming_up}, fn t, {s, _} -> Compute.step(spec, s, t) end)
  end

  describe "busy symbols keep the configured window" do
    test ":ofi at 10ms spacing covers the full 5m window" do
      # Bid size grows by 1 every update -> each update contributes +1.
      ticks =
        busy_ticks(40_000, fn i, at ->
          %{at: at, value: nil, bid: 100.0, bid_size: 1_000 + i, ask: 100.02, ask_size: 500}
        end)

      {state, value} = fold(%Spec{kind: :ofi, symbol: "SPY", window_ms: 300_000}, ticks)

      # 5m at 10ms = 30_000 intervals, both ends inclusive.
      assert TickWindow.sum_size(state.window) == 30_001
      assert Decimal.equal?(value, Decimal.new(30_001))
      assert Map.get(state, :cap_bound_drops, 0) == 0
    end

    test ":signed_volume at 10ms spacing covers the full window" do
      # Rising prices: every trade is a buy by the tick rule.
      ticks = busy_ticks(40_000, fn i, at -> %{at: at, value: 100.0 + i * 0.0001, volume: 1} end)

      {state, value} = fold(%Spec{kind: :signed_volume, symbol: "SPY", window_ms: 300_000}, ticks)

      assert TickWindow.sum_size(state.window) == 30_001
      assert Decimal.equal?(value, Decimal.new(30_001))
    end

    test "a cap that binds is reported, not silent" do
      ticks =
        busy_ticks(3_000, fn i, at ->
          %{at: at, value: nil, bid: 100.0, bid_size: 1_000 + i, ask: 100.02, ask_size: 500}
        end)

      spec = %Spec{
        kind: :ofi,
        symbol: "SPY",
        window_ms: 300_000,
        params: %{"max_history_samples" => 1_000}
      }

      {state, _} = fold(spec, ticks)

      # 2_999 contributions (the first book has none), 1_000 kept.
      assert state.cap_bound_drops == 1_999
    end

    test ":two_scale_rv recovers a known variance over the full 5m window" do
      :rand.seed(:exsss, {7, 8, 9})
      sigma = 0.0001
      n = 40_000

      logs = Enum.scan(1..n, :math.log(100.0), fn _, l -> l + sigma * :rand.normal() end)
      # iid microstructure noise, 2bp
      prices = Enum.map(logs, fn l -> :math.exp(l) * (1 + 0.0002 * :rand.normal()) end)

      ticks =
        prices
        |> Enum.with_index()
        |> Enum.map(fn {p, i} -> %{at: DateTime.add(@now, i * 10, :millisecond), value: p} end)

      spec = %Spec{
        kind: :two_scale_rv,
        symbol: "SPY",
        window_ms: 300_000,
        params: %{"subsample_k" => 20}
      }

      {state, value} = fold(spec, ticks)

      # 30_000 returns in the window, each of variance sigma^2.
      true_var = 30_000 * sigma * sigma
      assert TickWindow.rv_size(state.rv) == 30_001
      assert_in_delta value, true_var, true_var * 0.15

      # What the old 1_000-sample cap measured: a window 30x too short.
      capped = %{spec | params: Map.put(spec.params, "max_history_samples", 1_000)}
      {capped_state, capped_value} = fold(capped, ticks)
      assert capped_value < true_var / 10
      assert capped_state.cap_bound_drops > 0
    end

    test ":two_scale_rv time mode is bounded by buckets, not ticks" do
      ticks = busy_ticks(40_000, fn i, at -> %{at: at, value: 100.0 + :math.sin(i / 50)} end)

      spec = %Spec{
        kind: :two_scale_rv,
        symbol: "SPY",
        window_ms: 300_000,
        params: %{"subsample_mode" => "time", "subsample_ms" => 1_000}
      }

      {state, value} = fold(spec, ticks)

      assert length(state.buckets) <= 301
      assert is_float(value)
      assert Map.get(state, :cap_bound_drops, 0) == 0
    end
  end

  describe "a slow feed is unchanged" do
    test ":signed_volume at 1 trade/sec equals an independent windowed tick-rule sum" do
      trades =
        Enum.map(0..299, fn i ->
          {DateTime.add(@now, i, :second), 100.0 + rem(i, 7) * 0.01, i + 1}
        end)

      # Tick rule by hand: up-tick buy, down-tick sell, unchanged repeats.
      {signed, _} =
        Enum.map_reduce(Enum.with_index(trades), {nil, nil}, fn {{at, p, v}, i}, {prev, sign} ->
          sign =
            cond do
              i == 0 -> nil
              p > prev -> 1
              p < prev -> -1
              true -> sign
            end

          {{at, if(sign, do: sign * v)}, {p, sign}}
        end)

      spec = %Spec{kind: :signed_volume, symbol: "SPY", window_ms: 60_000}
      {:ok, state} = Compute.init(spec)

      trades
      |> Enum.zip(signed)
      |> Enum.reduce(state, fn {{at, p, v}, _}, s ->
        {s, value} = Compute.step(spec, s, %{at: at, value: p, volume: v})

        if value != :warming_up do
          cutoff = DateTime.add(at, -60_000, :millisecond)

          expected =
            signed
            |> Enum.filter(fn {t, sv} ->
              sv != nil and DateTime.compare(t, cutoff) != :lt and DateTime.compare(t, at) != :gt
            end)
            |> Enum.map(&elem(&1, 1))
            |> Enum.sum()

          assert Decimal.equal?(value, Decimal.new(expected)), "at #{at}: #{value} vs #{expected}"
        end

        s
      end)
    end
  end

  describe "kinds still on a per-tick cap report it binding" do
    test ":momentum" do
      ticks = busy_ticks(2_000, fn i, at -> %{at: at, value: 100.0 + i * 0.001} end)
      {state, _} = fold(%Spec{kind: :momentum, symbol: "SPY", window_ms: 300_000}, ticks)
      # 2_000 ticks in window, default cap 500.
      assert state.cap_bound_drops == 1_500
    end

    test ":rolling_volume" do
      ticks = busy_ticks(2_000, fn i, at -> %{at: at, value: i * 10} end)
      {state, _} = fold(%Spec{kind: :rolling_volume, symbol: "SPY", window_ms: 300_000}, ticks)
      assert state.cap_bound_drops == 1_500
    end
  end

  describe "window extremes (donchian)" do
    property "bands match a brute-force max/min over the window" do
      check all(
              gaps <- list_of(integer(0..3_000), min_length: 1, max_length: 200),
              cents <- list_of(integer(9_000..11_000), length: length(gaps)),
              window_ms <- integer(1..20_000)
            ) do
        stamps = Enum.scan(gaps, 0, &(&1 + &2))

        Enum.zip(stamps, cents)
        |> Enum.reduce({TickWindow.extremes_new(), []}, fn {ms, c}, {w, seen} ->
          at = DateTime.add(@now, ms, :millisecond)
          price = Decimal.new(c) |> Decimal.div(100)
          {w, 0} = TickWindow.extremes_push(w, at, price, at, window_ms, 1_000_000)
          seen = [{at, price} | seen]
          cutoff = DateTime.add(at, -window_ms, :millisecond)
          in_window = Enum.filter(seen, fn {t, _} -> DateTime.compare(t, cutoff) != :lt end)

          assert TickWindow.extremes_bands(w) == Signals.donchian_bands(in_window)
          assert TickWindow.extremes_size(w) == length(in_window)
          {w, seen}
        end)
      end
    end

    test "a 20m window on a 10ms feed still sees a high set 15 minutes ago" do
      # 20 minutes at 10ms = 120_000 ticks; a spike at minute 5, flat after.
      spike = 30_000

      ticks =
        busy_ticks(120_001, fn i, at ->
          %{at: at, value: if(i == spike, do: 150.0, else: 100.0 + rem(i, 3) * 0.01)}
        end)

      spec = %Spec{kind: :donchian, symbol: "SPY", window_ms: 1_200_000}
      {state, value} = fold(spec, ticks)

      assert {upper, _middle, lower} = Compute.donchian_bands(state)
      assert Decimal.equal?(upper, Decimal.from_float(150.0))
      assert Decimal.equal?(lower, Decimal.from_float(100.0))
      # The last tick (100.00) sits on the window low.
      assert Decimal.equal?(value, Decimal.new(-1))
      assert Map.get(state, :cap_bound_drops, 0) == 0

      {newest, oldest} = Compute.donchian_span(state)
      assert DateTime.diff(newest, oldest, :millisecond) == 1_200_000
    end

    test "a binding cap is reported" do
      ticks = busy_ticks(3_000, fn i, at -> %{at: at, value: 100.0 + i * 0.001} end)

      spec = %Spec{
        kind: :donchian,
        symbol: "SPY",
        window_ms: 1_200_000,
        params: %{"max_history_samples" => 1_000}
      }

      {state, _} = fold(spec, ticks)
      assert state.cap_bound_drops == 2_000
    end

    test "breakout on a slow feed matches Signals.donchian/4" do
      prices = [100.0, 101.0, 100.5, 102.0, 99.0, 99.5, 103.0, 101.0, 98.0, 100.0]
      spec = %Spec{kind: :donchian, symbol: "SPY", window_ms: 5_000}
      {:ok, state} = Compute.init(spec)

      prices
      |> Enum.with_index()
      |> Enum.reduce({state, []}, fn {p, i}, {s, hist} ->
        at = DateTime.add(@now, i, :second)
        {s, value} = Compute.step(spec, s, %{at: at, value: p})
        {hist, expected} = Signals.donchian(hist, p, at, window_ms: 5_000)
        assert value == if(expected, do: expected, else: :warming_up)
        {s, hist}
      end)
    end
  end

  describe "rolling OLS (kyle_lambda)" do
    property "matches the batch fit over the same window" do
      check all(
              gaps <- list_of(integer(0..2_000), min_length: 2, max_length: 200),
              xs <- list_of(integer(-50..50), length: length(gaps)),
              noise <- list_of(float(min: -1.0e-4, max: 1.0e-4), length: length(gaps)),
              window_ms <- integer(1..20_000)
            ) do
        stamps = Enum.scan(gaps, 0, &(&1 + &2))

        [stamps, xs, noise]
        |> Enum.zip()
        |> Enum.reduce({TickWindow.ols_new(), []}, fn {ms, x, e}, {o, hist} ->
          at = DateTime.add(@now, ms, :millisecond)
          x = x * 100.0
          y = 2.0e-7 * x + e
          {o, 0} = TickWindow.ols_push(o, at, x, y, at, window_ms, 1_000_000)

          {hist, batch} =
            Signals.rolling_ols_beta(hist, {x, y}, at,
              window_ms: window_ms,
              max_history_samples: 1_000_000,
              precision: 12
            )

          case {TickWindow.ols_value(o), batch} do
            {nil, nil} ->
              :ok

            {{beta, _}, {b, _}} ->
              assert_in_delta beta,
                              Decimal.to_float(b),
                              1.0e-9 + abs(Decimal.to_float(b)) * 1.0e-6

            other ->
              flunk("mismatch: #{inspect(other)}")
          end

          {o, hist}
        end)
      end
    end

    test "a 1m window on a 10ms trade feed keeps every trade" do
      ticks =
        busy_ticks(12_000, fn i, at ->
          mid = 100.0 + :math.sin(i / 10)
          %{at: at, value: mid + 0.01, volume: 1 + rem(i, 5), bid: mid - 0.01, ask: mid + 0.01}
        end)

      {state, _} = fold(%Spec{kind: :kyle_lambda, symbol: "SPY", window_ms: 60_000}, ticks)

      # 1m at 10ms = 6_001 points, both ends inclusive.
      assert TickWindow.ols_size(state.ols) == 6_001
      assert Map.get(state, :cap_bound_drops, 0) == 0
    end
  end
end
