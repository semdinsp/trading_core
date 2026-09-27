defmodule TradingCore.VolatilityTest do
  use ExUnit.Case, async: true

  alias TradingCore.Volatility

  defp day_bar(date, close), do: %{ts: DateTime.new!(date, ~T[20:00:00], "Etc/UTC"), close: close}

  # Closes whose absolute log returns are exactly `returns`, one bar per day.
  defp bars_from_returns(start, returns, signs) do
    {bars, _} =
      returns
      |> Enum.zip(signs)
      |> Enum.with_index(1)
      |> Enum.map_reduce(100.0, fn {{r, sign}, i}, close ->
        next = close * :math.exp(sign * r)
        {day_bar(Date.add(start, i), next), next}
      end)

    [day_bar(start, 100.0) | bars]
  end

  describe "ewma_vol/2" do
    test "matches the hub's trailing_ewma_vol/2 doc example" do
      # TradingHub.Volatility.Calculator.trailing_ewma_vol/2 doctest:
      # [0.01, 0.012, 0.008] oldest first -> 0.010094468082875216
      assert_in_delta Volatility.ewma_vol([0.01, 0.012, 0.008]), 0.010094468082875216, 1.0e-15
    end

    test "weights the most recent return most" do
      assert Volatility.ewma_vol([0.01, 0.03], 0.5) > Volatility.ewma_vol([0.03, 0.01], 0.5)
    end
  end

  describe "ewma_daily_vol/2" do
    test "reproduces the hub figure from bars" do
      bars = bars_from_returns(~D[2026-09-01], [0.01, 0.012, 0.008], [1, -1, 1])

      assert {:ok, vol} = Volatility.ewma_daily_vol(bars)
      assert_in_delta Decimal.to_float(vol), 0.010094468082875216, 1.0e-12
    end

    test "uses only as_of - 14 through as_of calendar days, both inclusive" do
      # A huge move 20 days back must be ignored; the rest are 1% moves.
      old = [day_bar(~D[2026-08-01], 100.0), day_bar(~D[2026-08-02], 200.0)]

      recent =
        bars_from_returns(
          ~D[2026-08-16],
          List.duplicate(0.01, 14),
          Stream.cycle([1, -1]) |> Enum.take(14)
        )

      assert {:ok, vol} = Volatility.ewma_daily_vol(old ++ recent, as_of: ~D[2026-08-30])
      assert_in_delta Decimal.to_float(vol), 0.01, 1.0e-12
    end

    test "as_of drops later bars" do
      bars = bars_from_returns(~D[2026-09-01], [0.01, 0.01, 0.5], [1, -1, 1])

      assert {:ok, vol} = Volatility.ewma_daily_vol(bars, as_of: ~D[2026-09-03])
      assert_in_delta Decimal.to_float(vol), 0.01, 1.0e-12
    end

    test "intraday bars collapse to the last close of each UTC day" do
      at = fn date, time, close -> %{ts: DateTime.new!(date, time, "Etc/UTC"), close: close} end
      up = 100.0 * :math.exp(0.02)

      bars = [
        at.(~D[2026-09-01], ~T[14:00:00], 90.0),
        at.(~D[2026-09-01], ~T[20:00:00], 100.0),
        at.(~D[2026-09-02], ~T[14:00:00], 130.0),
        at.(~D[2026-09-02], ~T[20:00:00], up)
      ]

      assert {:ok, vol} = Volatility.ewma_daily_vol(bars)
      assert_in_delta Decimal.to_float(vol), 0.02, 1.0e-12
    end

    test "accepts Decimal closes" do
      bars = [
        day_bar(~D[2026-09-01], Decimal.new("100")),
        day_bar(~D[2026-09-02], Decimal.new("101"))
      ]

      assert {:ok, vol} = Volatility.ewma_daily_vol(bars)
      assert_in_delta Decimal.to_float(vol), :math.log(1.01), 1.0e-12
    end

    test "insufficient data with fewer than two days" do
      assert Volatility.ewma_daily_vol([]) == :insufficient_data
      assert Volatility.ewma_daily_vol([day_bar(~D[2026-09-01], 100.0)]) == :insufficient_data
    end
  end

  describe "atr/2" do
    defp ohlc(h, l, c), do: %{high: Decimal.new(h), low: Decimal.new(l), close: Decimal.new(c)}

    test "seeds with the simple mean, then applies Wilder smoothing" do
      bars = [
        # TR = 2 (no previous close)
        ohlc("11", "9", "10"),
        # TR = max(2, |12-10|, |10-10|) = 2
        ohlc("12", "10", "11"),
        # gap up: TR = max(1, |15-11|, |14-11|) = 4
        ohlc("15", "14", "14"),
        # TR = max(3, |14-14|, |11-14|) = 3
        ohlc("14", "11", "12")
      ]

      # period 2: seed = (2 + 2) / 2 = 2; then (2*1 + 4)/2 = 3; then (3*1 + 3)/2 = 3
      assert {:ok, atr} = Volatility.atr(bars, 2)
      assert Decimal.equal?(atr, Decimal.new(3))

      # period 4: just the mean of all four = 11/4
      assert {:ok, atr4} = Volatility.atr(bars, 4)
      assert Decimal.equal?(atr4, Decimal.new("2.75"))
    end

    test "insufficient data with fewer bars than the period" do
      assert Volatility.atr([ohlc("11", "9", "10")], 2) == :insufficient_data
    end
  end
end
