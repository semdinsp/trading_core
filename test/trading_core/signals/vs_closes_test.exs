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
end
