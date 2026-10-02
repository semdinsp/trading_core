Code.require_file("../../support/intraday_bars.exs", __DIR__)

defmodule TradingCore.Intraday.OpeningRangeTest do
  use ExUnit.Case, async: true

  import TradingCore.IntradayBars

  alias TradingCore.Intraday.OpeningRange

  # Thursday, EDT (09:30 ET = 13:30 UTC).
  @day ~D[2026-10-01]

  defp d(s), do: Decimal.new(s)

  # A rising first 30 minutes: minute m opens at 100 + m/10 and closes
  # 0.05 higher; high/low are ±0.20 around the open. Minute 3 has the
  # session's deepest low and minute 12 a spike high.
  defp session_bars do
    for minute <- 0..40 do
      open = Decimal.add(100, Decimal.div(minute, 10))
      high = if minute == 12, do: d("110.0"), else: Decimal.add(open, d("0.2"))
      low = if minute == 3, do: d("95.0"), else: Decimal.sub(open, d("0.2"))
      bar(@day, minute, open, high, low, Decimal.add(open, d("0.05")))
    end
  end

  defp assert_range(range, %{open: o, close: c, high: h, low: l, direction: dir}) do
    assert Decimal.equal?(range.open, d(o))
    assert Decimal.equal?(range.close, d(c))
    assert Decimal.equal?(range.high, d(h))
    assert Decimal.equal?(range.low, d(l))
    assert range.direction == dir
  end

  describe "from_bars/4" do
    test "5, 15 and 30 minute ranges" do
      bars = session_bars()

      # minutes 0..4: open 100.0, last close 100.4 + 0.05, high 100.4 + 0.2
      assert {:ok, r5} = OpeningRange.from_bars(bars, @day, 5)

      assert_range(r5, %{open: "100.0", close: "100.45", high: "100.6", low: "95.0", direction: 1})

      # minutes 0..14 include the minute-12 spike
      assert {:ok, r15} = OpeningRange.from_bars(bars, @day, 15)

      assert_range(r15, %{
        open: "100.0",
        close: "101.45",
        high: "110.0",
        low: "95.0",
        direction: 1
      })

      # minutes 0..29
      assert {:ok, r30} = OpeningRange.from_bars(bars, @day, 30)

      assert_range(r30, %{
        open: "100.0",
        close: "102.95",
        high: "110.0",
        low: "95.0",
        direction: 1
      })
    end

    test "direction follows close vs open of the range" do
      down = [bar(@day, 0, 100, 101, 99, 99.5), bar(@day, 4, 99.5, 99.6, 98, 98.0)]
      assert {:ok, %{direction: -1}} = OpeningRange.from_bars(down, @day, 5)

      flat = [bar(@day, 0, 100, 101, 99, 99.5), bar(@day, 4, 99.5, 101, 99, 100.0)]
      assert {:ok, %{direction: 0}} = OpeningRange.from_bars(flat, @day, 5)
    end

    test "pre-market and other-day bars are ignored" do
      bars = [
        bar(@day, -1, 50, 200, 1, 50),
        bar(~D[2026-09-30], 0, 50, 200, 1, 50) | Enum.map(0..4, &flat(@day, &1, 100))
      ]

      assert {:ok, range} = OpeningRange.from_bars(bars, @day, 5)
      assert_range(range, %{open: "100", close: "100", high: "100", low: "100", direction: 0})
    end

    test ":incomplete until the range's last minute, a later bar, or now has passed" do
      first_four = Enum.map(0..3, &flat(@day, &1, 100))

      assert OpeningRange.from_bars(first_four, @day, 5) == {:error, :incomplete}

      # 1. the last minute's bar arrives
      assert {:ok, _} = OpeningRange.from_bars(first_four ++ [flat(@day, 4, 100)], @day, 5)

      # 2. a later bar proves minute 4 had no trades
      assert {:ok, _} = OpeningRange.from_bars(first_four ++ [flat(@day, 7, 100)], @day, 5)

      # 3. the caller's clock says the range is over
      assert OpeningRange.from_bars(first_four, @day, 5, now: at_et(@day, ~T[09:34:59])) ==
               {:error, :incomplete}

      assert {:ok, _} =
               OpeningRange.from_bars(first_four, @day, 5, now: at_et(@day, ~T[09:35:00]))
    end

    test "a gap inside the range is fine once the range has ended" do
      bars = [flat(@day, 0, 100), flat(@day, 4, 101)]
      assert {:ok, %{close: close}} = OpeningRange.from_bars(bars, @day, 5)
      assert Decimal.equal?(close, 101)
    end

    test "an ended range with no trades is :no_bars" do
      assert OpeningRange.from_bars([flat(@day, 10, 100)], @day, 5) == {:error, :no_bars}
    end

    test "weekends and holidays are :no_session" do
      assert OpeningRange.from_bars([], ~D[2026-10-03], 5) == {:error, :no_session}
      assert OpeningRange.from_bars([], ~D[2026-11-26], 5) == {:error, :no_session}
    end

    test "a range longer than a half day is cut at its 13:00 close" do
      half_day = ~D[2026-11-27]
      bars = Enum.map(0..209, &flat(half_day, &1, 100 + &1))

      assert {:ok, range} = OpeningRange.from_bars(bars, half_day, 400)
      assert Decimal.equal?(range.close, 309)
      assert Decimal.equal?(range.high, 309)
    end
  end

  describe "position/2" do
    @range %{high: Decimal.new("101"), low: Decimal.new("99")}

    test "above, below, at the edges and inside" do
      assert OpeningRange.position(d("101.01"), @range) == 1
      assert OpeningRange.position(d("98.99"), @range) == -1
      assert OpeningRange.position(d("101"), @range) == 0
      assert OpeningRange.position(d("99"), @range) == 0
      assert OpeningRange.position(100, @range) == 0
      assert OpeningRange.position(101.5, @range) == 1
    end

    test "unparseable input is 0" do
      assert OpeningRange.position(nil, @range) == 0
      assert OpeningRange.position("x", @range) == 0
      assert OpeningRange.position(d("100"), %{high: nil, low: nil}) == 0
      assert OpeningRange.position(d("100"), :nope) == 0
    end
  end
end
