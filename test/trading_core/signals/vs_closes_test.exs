defmodule TradingCore.Signals.VsClosesTest do
  use ExUnit.Case, async: true

  alias TradingCore.Signals.VsCloses

  defp d(v), do: Decimal.new(v)

  # A daily bar stamped at 16:00 ET on `date` (Unix ms, like Polygon).
  defp bar(date, close) do
    ts = date |> DateTime.new!(~T[16:00:00], "America/New_York") |> DateTime.to_unix(:millisecond)
    %{timestamp: ts, close: close}
  end

  # Trading days ending Thu 2026-10-08, closes 20, 21, 22, 23, 24 oldest first.
  @days [~D[2026-10-02], ~D[2026-10-05], ~D[2026-10-06], ~D[2026-10-07], ~D[2026-10-08]]
  defp five_bars, do: Enum.zip_with(@days, [20, 21, 22, 23, 24], &bar/2)

  describe "closes_before/4" do
    test "the last N strictly before today, newest first, as Decimals" do
      assert VsCloses.closes_before(five_bars(), ~D[2026-10-09], 3) == [d(24), d(23), d(22)]
    end

    test "today's own bar is excluded" do
      bars = five_bars() ++ [bar(~D[2026-10-09], 99)]
      assert VsCloses.closes_before(bars, ~D[2026-10-09], 3) == [d(24), d(23), d(22)]
      assert VsCloses.closes_before(bars, ~D[2026-10-08], 3) == [d(23), d(22), d(21)]
    end

    test "too few closes is nil" do
      assert VsCloses.closes_before(five_bars(), ~D[2026-10-09], 6) == nil
      assert VsCloses.closes_before([], ~D[2026-10-09], 1) == nil
    end

    test "stale closes: newest more than max_staleness_days before today is nil" do
      # newest 10-08; 10-13 is 5 days later (ok), 10-14 is 6 (stale)
      assert VsCloses.closes_before(five_bars(), ~D[2026-10-13], 5) != nil
      assert VsCloses.closes_before(five_bars(), ~D[2026-10-14], 5) == nil
      assert VsCloses.closes_before(five_bars(), ~D[2026-10-14], 5, max_staleness_days: 6) != nil
    end

    test "accepts DateTime timestamps and ignores unusable bars" do
      bars = [
        %{timestamp: ~U[2026-10-08 20:00:00Z], close: 24.0},
        %{timestamp: nil, close: 1},
        %{timestamp: 1_791_500_000_000, close: "x"},
        bar(~D[2026-10-07], 23)
      ]

      assert VsCloses.closes_before(bars, ~D[2026-10-09], 2) == [Decimal.from_float(24.0), d(23)]
    end
  end

  describe "baseline/2" do
    test "pct: mean and n" do
      assert VsCloses.baseline([d(20), d(22), d(24)], "pct") == %{mean: 22.0, n: 3}
    end

    test "zscore: the sample standard deviation (n - 1)" do
      # values 20, 22, 24: mean 22, squared deviations 4 + 0 + 4 = 8, / 2 = 4, sd 2
      assert VsCloses.baseline([d(20), d(22), d(24)], "zscore") == %{mean: 22.0, sd: 2.0, n: 3}
    end

    test "nil for no closes, or zscore with fewer than 3" do
      assert VsCloses.baseline([], "pct") == nil
      assert VsCloses.baseline(nil, "zscore") == nil
      assert VsCloses.baseline([d(1), d(2)], "zscore") == nil
      assert VsCloses.baseline([d(1), d(2)], "pct") == %{mean: 1.5, n: 2}
    end
  end

  describe "compute/3" do
    test "pct: (price / mean - 1) * 100, rounded to 8 places" do
      base = VsCloses.baseline([d(20), d(22), d(24)], "pct")
      assert VsCloses.compute(d("24.2"), base, "pct") == Decimal.new("10.00000000")
      assert VsCloses.compute(21, base, "pct") == Decimal.new("-4.54545455")
    end

    test "zscore: (price - mean) / sd" do
      base = VsCloses.baseline([d(20), d(22), d(24)], "zscore")
      assert VsCloses.compute(d(25), base, "zscore") == Decimal.new("1.50000000")
      assert VsCloses.compute(19.0, base, "zscore") == Decimal.new("-1.50000000")
    end

    test "flat closes give no zscore" do
      base = VsCloses.baseline([d(20), d(20), d(20)], "zscore")
      assert VsCloses.compute(d(25), base, "zscore") == nil
    end

    test "nil price, non-numeric price, nil baseline, non-positive mean" do
      base = VsCloses.baseline([d(20), d(22), d(24)], "pct")
      assert VsCloses.compute(nil, base, "pct") == nil
      assert VsCloses.compute("x", base, "pct") == nil
      assert VsCloses.compute(d(10), nil, "pct") == nil
      assert VsCloses.compute(d(10), %{mean: 0.0, n: 1}, "pct") == nil
    end

    test "matches trading_signal's float arithmetic to the digit" do
      closes = [d("17.23"), d("16.88"), d("18.41"), d("19.02"), d("17.65")]
      zbase = VsCloses.baseline(closes, "zscore")

      floats = Enum.map(closes, &Decimal.to_float/1)
      mean = Enum.sum(floats) / 5
      sd = :math.sqrt(Enum.sum(Enum.map(floats, &((&1 - mean) ** 2))) / 4)

      assert VsCloses.compute(d("21.07"), zbase, "zscore") ==
               ((21.07 - mean) / sd) |> Decimal.from_float() |> Decimal.round(8)
    end
  end

  describe "series/5" do
    test "each tick against its own date's baseline, no look-ahead" do
      bars = five_bars() ++ [bar(~D[2026-10-09], 30)]

      ticks = [
        {~U[2026-10-08 14:00:00Z], d(25)},
        {~U[2026-10-08 19:00:00Z], d(26)},
        {~U[2026-10-09 14:00:00Z], d(27)}
      ]

      expected =
        Enum.map(ticks, fn {at, price} ->
          date = at |> DateTime.shift_zone!("America/New_York") |> DateTime.to_date()
          base = bars |> VsCloses.closes_before(date, 3) |> VsCloses.baseline("zscore")
          {at, VsCloses.compute(price, base, "zscore")}
        end)

      assert VsCloses.series(ticks, bars, 3, "zscore") == expected

      # 10-08 ticks use 10-05..10-07 (21, 22, 23: mean 22, sd 1), so 25 is
      # z = 3; 10-09 uses 22, 23, 24 (mean 23, sd 1), so 27 is z = 4,
      # never touching 10-09's own close of 30.
      [{_, z1}, _, {_, z3}] = expected
      assert z1 == Decimal.new("3.00000000")
      assert z3 == Decimal.new("4.00000000")
    end

    test "a date with too few closes yields nil for its ticks" do
      assert VsCloses.series([{~U[2026-10-03 14:00:00Z], d(25)}], five_bars(), 3, "pct") ==
               [{~U[2026-10-03 14:00:00Z], nil}]
    end
  end

  describe "realized_vol" do
    # Six closes alternating +1% / -1%, 2026-10-01 .. 2026-10-08, plus a
    # wild close on 2026-10-09 that a 10-09 session must never see.
    @rv_days [
      ~D[2026-10-01],
      ~D[2026-10-02],
      ~D[2026-10-05],
      ~D[2026-10-06],
      ~D[2026-10-07],
      ~D[2026-10-08]
    ]
    defp rv_closes, do: Enum.scan([100.0, 1.01, 0.99, 1.01, 0.99, 1.01], &(&1 * &2))
    defp rv_bars, do: Enum.zip_with(@rv_days, rv_closes(), &bar/2)

    # sqrt(mean(r^2)) * sqrt(252) * 100 over three ln(1.01) and two ln(0.99)
    @rv_expected :math.sqrt((3 * :math.log(1.01) ** 2 + 2 * :math.log(0.99) ** 2) / 5) *
                   :math.sqrt(252) * 100

    test "closes_needed: days returns need days + 1 closes; other outputs unchanged" do
      assert VsCloses.closes_needed(5, "realized_vol") == 6
      assert VsCloses.closes_needed(5, "pct") == 5
      assert VsCloses.closes_needed(5, "zscore") == 5
    end

    test "zero-mean annualized RMS of log returns, in percent" do
      closes = VsCloses.closes_before(rv_bars(), ~D[2026-10-09], 6)
      assert %{rv: rv, n: 5} = VsCloses.baseline(closes, "realized_vol")
      assert_in_delta rv, @rv_expected, 1.0e-9
      assert_in_delta rv, 15.86, 0.01
    end

    test "zero-mean, not demeaned: a steady trend has positive vol" do
      # +1% every day: the sample sd would be 0, the RMS is ln(1.01) annualized
      closes = Enum.scan([100.0, 1.01, 1.01, 1.01], &(&1 * &2)) |> Enum.reverse()
      %{rv: rv} = VsCloses.baseline(closes, "realized_vol")
      assert_in_delta rv, :math.log(1.01) * :math.sqrt(252) * 100, 1.0e-9
    end

    test "nil for fewer than 2 closes or a non-positive close" do
      assert VsCloses.baseline([d(100)], "realized_vol") == nil
      assert VsCloses.baseline([d(100), d(0), d(99)], "realized_vol") == nil
      assert VsCloses.baseline([d(100), d(-1)], "realized_vol") == nil
      assert VsCloses.baseline(nil, "realized_vol") == nil
    end

    test "compute ignores the price, rounds to 8 places, nil for a nil baseline" do
      base = %{rv: 15.123456789, n: 5}
      assert VsCloses.compute(d(10), base, "realized_vol") == Decimal.new("15.12345679")
      assert VsCloses.compute(d(9999), base, "realized_vol") == Decimal.new("15.12345679")
      assert VsCloses.compute(nil, base, "realized_vol") == Decimal.new("15.12345679")
      assert VsCloses.compute(d(10), nil, "realized_vol") == nil
    end

    test "series: no look-ahead, needs days + 1 prior closes, same value all session" do
      bars = rv_bars() ++ [bar(~D[2026-10-09], 500.0)]

      ticks = [
        # 10-08: only 5 prior closes (10-01..10-07) -> nil for 5 returns
        {~U[2026-10-08 14:00:00Z], d(1)},
        # 10-09: 6 prior closes; its own 500 close never counts
        {~U[2026-10-09 14:00:00Z], d(1)},
        {~U[2026-10-09 19:00:00Z], d(2)}
      ]

      expected = @rv_expected |> Decimal.from_float() |> Decimal.round(8)

      assert [{_, nil}, {_, ^expected}, {_, ^expected}] =
               VsCloses.series(ticks, bars, 5, "realized_vol")
    end

    test "series: a stale newest close is nil" do
      ticks = [{~U[2026-10-20 14:00:00Z], d(1)}]
      assert [{_, nil}] = VsCloses.series(ticks, rv_bars(), 5, "realized_vol")

      assert [{_, %Decimal{}}] =
               VsCloses.series(ticks, rv_bars(), 5, "realized_vol", max_staleness_days: 12)
    end
  end

  describe "rsi and daily atr" do
    # Consecutive weekdays ending Tue 2026-10-20, oldest first.
    defp weekdays(n) do
      Stream.iterate(~D[2026-10-20], &Date.add(&1, -1))
      |> Stream.reject(&(Date.day_of_week(&1) in [6, 7]))
      |> Enum.take(n)
      |> Enum.reverse()
    end

    defp walk(n), do: Enum.scan(1..n, 100.0, fn i, acc -> acc + :math.sin(i * 1.7) * 1.3 end)

    defp ohlc_bars(n) do
      Enum.zip_with(weekdays(n), walk(n), fn date, c ->
        date
        |> bar(c)
        |> Map.merge(%{high: c + 0.8 + rem(round(c * 10), 3) * 0.2, low: c - 0.9})
      end)
    end

    # Independent Wilder RSI over a whole close series (oldest first).
    defp reference_rsi(closes, p) do
      changes = closes |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> b - a end)
      {seed, rest} = Enum.split(changes, p)
      g0 = Enum.sum(Enum.map(seed, &max(&1, 0.0))) / p
      l0 = Enum.sum(Enum.map(seed, &max(-&1, 0.0))) / p

      {g, l} =
        Enum.reduce(rest, {g0, l0}, fn c, {g, l} ->
          {(g * (p - 1) + max(c, 0.0)) / p, (l * (p - 1) + max(-c, 0.0)) / p}
        end)

      100 - 100 / (1 + g / l)
    end

    test "closes_needed: 10 x period + 1 for the Wilder outputs" do
      assert VsCloses.closes_needed(2, "rsi") == 21
      assert VsCloses.closes_needed(14, "atr") == 141
      assert VsCloses.closes_needed(14, "atr_pct") == 141
    end

    test "rsi: prior closes plus the live price as today's provisional close" do
      closes = walk(21)

      prior =
        VsCloses.closes_before(Enum.zip_with(weekdays(21), closes, &bar/2), ~D[2026-10-21], 21)

      base = VsCloses.baseline(prior, "rsi", 2)

      for live <- [95.0, 100.0, 104.0] do
        want = reference_rsi(closes ++ [live], 2) |> Decimal.from_float() |> Decimal.round(8)
        assert VsCloses.compute(live, base, "rsi") == want
      end
    end

    test "rsi: 100 with no losses, 50 with no change, nil without enough closes" do
      up = for i <- 0..20, do: 100.0 + i

      assert VsCloses.compute(121.0, VsCloses.baseline(Enum.reverse(up), "rsi", 2), "rsi") ==
               Decimal.new("100.00000000")

      flat = List.duplicate(100.0, 21)

      assert VsCloses.compute(100.0, VsCloses.baseline(flat, "rsi", 2), "rsi") ==
               Decimal.new("50.00000000")

      assert VsCloses.baseline([d(1), d(2)], "rsi", 2) == nil
      assert_raise ArgumentError, fn -> VsCloses.baseline([d(1), d(2), d(3)], "rsi") end
    end

    test "rsi series: no look-ahead, today's own close never counts" do
      bars = Enum.zip_with(weekdays(21), walk(21), &bar/2) ++ [bar(~D[2026-10-21], 999.0)]
      ticks = [{~U[2026-10-21 14:00:00Z], 101.0}, {~U[2026-10-21 19:00:00Z], 97.0}]
      [{_, a}, {_, b}] = VsCloses.series(ticks, bars, 2, "rsi")

      base = bars |> VsCloses.closes_before(~D[2026-10-21], 21) |> VsCloses.baseline("rsi", 2)
      assert a == VsCloses.compute(101.0, base, "rsi")
      assert b == VsCloses.compute(97.0, base, "rsi")
      # one fewer prior close: nil
      assert [{_, nil}] = VsCloses.series(ticks |> Enum.take(1), tl(bars), 2, "rsi")
    end

    test "daily atr / atr_pct: Wilder over prior bars, each TR with its previous close" do
      bars = ohlc_bars(31)
      prior = VsCloses.bars_before(bars, ~D[2026-10-21], 31)
      base = VsCloses.baseline(prior, "atr", 3)

      rows = Enum.map(bars, &%{h: &1.high, l: &1.low, c: &1.close})

      trs =
        rows
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [p, r] -> Enum.max([r.h - r.l, abs(r.h - p.c), abs(r.l - p.c)]) end)

      {seed, rest} = Enum.split(trs, 3)
      want = Enum.reduce(rest, Enum.sum(seed) / 3, fn tr, a -> (a * 2 + tr) / 3 end)

      assert_in_delta base.atr, want, 1.0e-9
      assert VsCloses.compute(123.0, base, "atr") == VsCloses.compute(nil, base, "atr")

      assert VsCloses.compute(nil, base, "atr_pct") ==
               (want / List.last(rows).c * 100) |> Decimal.from_float() |> Decimal.round(8)
    end

    test "daily atr series: needs 10 x period + 1 prior bars; ignores bars without high/low" do
      bars = ohlc_bars(31)
      ticks = [{~U[2026-10-21 14:00:00Z], 1.0}]
      assert [{_, %Decimal{}}] = VsCloses.series(ticks, bars, 3, "atr")
      assert [{_, nil}] = VsCloses.series(ticks, tl(bars), 3, "atr")

      no_range = Enum.map(bars, &Map.drop(&1, [:high]))
      assert [{_, nil}] = VsCloses.series(ticks, no_range, 3, "atr_pct")
    end
  end
end
