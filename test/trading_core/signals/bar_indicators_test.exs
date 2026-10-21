defmodule TradingCore.Signals.BarIndicatorsTest do
  use ExUnit.Case, async: true

  alias TradingCore.Signals.BarIndicators, as: BI
  alias TradingCore.Volatility

  @t0 ~U[2026-10-21 14:00:00Z]
  defp at(sec), do: DateTime.add(@t0, sec)

  # Pushes {second, value} ticks, returning the closed bars in order.
  defp closed_bars(ticks, interval_ms \\ 60_000) do
    {_b, bars} =
      Enum.reduce(ticks, {BI.bars_new(), []}, fn {sec, v}, {b, acc} ->
        case BI.bars_push(b, at(sec), v, interval_ms) do
          {b, nil} -> {b, acc}
          {b, bar} -> {b, [bar | acc]}
        end
      end)

    Enum.reverse(bars)
  end

  # Deterministic OHLC bars with up and down legs.
  defp fixture_bars do
    closes = [10.0, 10.6, 10.2, 11.1, 11.8, 11.4, 12.3, 12.0, 11.2, 10.9, 11.6, 12.4, 12.1, 13.0]

    closes
    |> Enum.with_index()
    |> Enum.map(fn {c, i} ->
      %{open: c - 0.1, high: c + 0.3 + rem(i, 3) * 0.1, low: c - 0.4 - rem(i, 2) * 0.1, close: c}
    end)
  end

  describe "bars" do
    test "OHLC from the ticks of each interval; a bar closes on the next interval's first tick" do
      bars = closed_bars([{0, 10.0}, {20, 12.0}, {40, 9.0}, {59, 11.0}, {60, 11.5}, {130, 11.0}])

      assert [
               %{open: 10.0, high: 12.0, low: 9.0, close: 11.0, start_ms: s0},
               %{open: 11.5, high: 11.5, low: 11.5, close: 11.5}
             ] = bars

      assert s0 == DateTime.to_unix(@t0, :millisecond)
    end

    test "a quiet interval makes no bar" do
      # minutes 0, 1 and 5 have ticks; minutes 2-4 are quiet
      bars = closed_bars([{0, 1.0}, {60, 2.0}, {300, 3.0}, {360, 4.0}])
      assert Enum.map(bars, & &1.close) == [1.0, 2.0, 3.0]
    end

    test "a late tick counts toward the open bar" do
      bars = closed_bars([{60, 5.0}, {10, 7.0}, {120, 6.0}])
      assert [%{open: 5.0, high: 7.0, close: 7.0}] = bars
    end
  end

  describe "ATR" do
    test "agrees bar for bar with Volatility.atr/2" do
      bars = fixture_bars()

      Enum.reduce(Enum.with_index(bars, 1), BI.atr_new(), fn {bar, n}, st ->
        st = BI.atr_push(st, bar, 5)

        case Volatility.atr(Enum.take(bars, n), 5) do
          :insufficient_data -> assert BI.atr_value(st) == nil
          {:ok, expected} -> assert_in_delta BI.atr_value(st), Decimal.to_float(expected), 1.0e-9
        end

        st
      end)
    end

    test "atr_pct is ATR over the last close, in percent" do
      st = Enum.reduce(fixture_bars(), BI.atr_new(), &BI.atr_push(&2, &1, 5))
      assert_in_delta BI.atr_pct_value(st), BI.atr_value(st) / 13.0 * 100, 1.0e-12
    end
  end

  describe "ADX" do
    # Textbook Wilder (original form): the first smoothed TR/DM is the SUM of
    # the first `p`, then S = S - S/p + x; ADX seeds with the mean of `p` DX.
    defp reference_adx(bars, p) do
      rows =
        bars
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [prev, b] ->
          up = b.high - prev.high
          down = prev.low - b.low
          tr = Enum.max([b.high - b.low, abs(b.high - prev.close), abs(b.low - prev.close)])

          {tr, if(up > down and up > 0, do: up, else: 0.0),
           if(down > up and down > 0, do: down, else: 0.0)}
        end)

      {seed, rest} = Enum.split(rows, p)
      sum = fn list, i -> list |> Enum.map(&elem(&1, i)) |> Enum.sum() end
      first = {sum.(seed, 0), sum.(seed, 1), sum.(seed, 2)}

      smoothed =
        Enum.scan(rest, first, fn {tr, pdm, mdm}, {s_tr, s_p, s_m} ->
          {s_tr - s_tr / p + tr, s_p - s_p / p + pdm, s_m - s_m / p + mdm}
        end)

      dis =
        Enum.map([first | smoothed], fn {s_tr, s_p, s_m} ->
          {100 * s_p / s_tr, 100 * s_m / s_tr}
        end)

      dxs = Enum.map(dis, fn {pd, md} -> 100 * abs(pd - md) / (pd + md) end)
      {dx_seed, dx_rest} = Enum.split(dxs, p)
      adx = Enum.reduce(dx_rest, Enum.sum(dx_seed) / p, fn dx, a -> (a * (p - 1) + dx) / p end)
      {List.last(dis), adx}
    end

    test "matches the textbook (summed-seed) Wilder ADX and DIs" do
      bars = fixture_bars()
      st = Enum.reduce(bars, BI.adx_new(), &BI.adx_push(&2, &1, 4))
      {{ref_pd, ref_md}, ref_adx} = reference_adx(bars, 4)

      {pd, md} = BI.di(st)
      assert_in_delta pd, ref_pd, 1.0e-9
      assert_in_delta md, ref_md, 1.0e-9
      assert_in_delta BI.adx_value(st), ref_adx, 1.0e-9
    end

    test "warm-up: DIs after period + 1 bars, ADX after 2 x period" do
      p = 4

      states =
        fixture_bars()
        |> Enum.scan(BI.adx_new(), &BI.adx_push(&2, &1, p))

      assert Enum.find_index(states, &(BI.di(&1) != nil)) == p
      assert Enum.find_index(states, &(BI.adx_value(&1) != nil)) == 2 * p - 1
    end

    test "a steady uptrend: -DI 0, DX and ADX 100" do
      bars = for i <- 0..9, do: %{open: i * 1.0, high: i + 0.5, low: i - 0.5, close: i * 1.0}
      st = Enum.reduce(bars, BI.adx_new(), &BI.adx_push(&2, &1, 3))
      assert {pd, +0.0} = BI.di(st)
      assert pd > 0
      assert_in_delta BI.adx_value(st), 100.0, 1.0e-9
    end

    test "flat bars give DI 0 and DX 0, not a division by zero" do
      bars = for _ <- 1..8, do: %{open: 5.0, high: 5.0, low: 5.0, close: 5.0}
      st = Enum.reduce(bars, BI.adx_new(), &BI.adx_push(&2, &1, 3))
      assert BI.di(st) == {0.0, 0.0}
      assert BI.adx_value(st) == 0.0
    end
  end
end
