Code.require_file("../../support/intraday_bars.exs", __DIR__)

defmodule TradingCore.Intraday.NoiseBandTest do
  use ExUnit.Case, async: true

  import TradingCore.IntradayBars

  alias TradingCore.Intraday.NoiseBand

  @today ~D[2026-10-01]

  defp d(s), do: Decimal.new(s)

  # One session: opens at 100 (minute 0), closes `close_at_5` at minute 5,
  # and trades on to minute 10 so minute 5 is covered.
  defp session(date, close_at_5) do
    [
      bar(date, 0, d("100"), d("100"), d("100"), d("100")),
      flat(date, 5, close_at_5),
      flat(date, 10, close_at_5)
    ]
  end

  describe "width/4" do
    test "mean |close_at_m / open − 1| over exactly the last L sessions" do
      # Most recent first: 09-30 +1%, 09-29 −2%, 09-28 +3%; 09-25's 10% is
      # beyond L = 3 and must not count. Mean = (0.01 + 0.02 + 0.03) / 3.
      bars =
        session(~D[2026-09-30], d("101")) ++
          session(~D[2026-09-29], d("98")) ++
          session(~D[2026-09-28], d("103")) ++
          session(~D[2026-09-25], d("110"))

      assert {:ok, width} = NoiseBand.width(bars, @today, 5, lookback: 3)
      assert Decimal.equal?(width, d("0.02"))
    end

    test "defaults to 14 sessions" do
      days = trading_days_before(@today, 15)

      # The 14 most recent move 1%; the 15th moves 50% and is excluded.
      bars =
        Enum.flat_map(Enum.take(days, 14), &session(&1, d("101"))) ++
          session(List.last(days), d("150"))

      assert {:ok, width} = NoiseBand.width(bars, @today, 5)
      assert Decimal.equal?(width, d("0.01"))

      assert NoiseBand.width(
               Enum.flat_map(Enum.take(days, 13), &session(&1, d("101"))),
               @today,
               5
             ) ==
               {:error, :insufficient_history}
    end

    test "a half day is skipped for minutes after its 13:00 close, not counted as zero" do
      # Monday 2026-11-30. Before it: 11-27 (half day, closes 13:00 =
      # minute 210), 11-26 (Thanksgiving), 11-25, 11-24, 11-23.
      today = ~D[2026-11-30]
      late = 300

      full_day = fn date, close ->
        [flat(date, 0, d("100")), flat(date, late, close), flat(date, 380, close)]
      end

      bars =
        [flat(~D[2026-11-27], 0, d("100")), flat(~D[2026-11-27], 200, d("150"))] ++
          full_day.(~D[2026-11-25], d("101")) ++
          full_day.(~D[2026-11-24], d("102")) ++
          full_day.(~D[2026-11-23], d("103"))

      # Minute 300 skips the half day: (0.01 + 0.02 + 0.03) / 3.
      assert {:ok, width} = NoiseBand.width(bars, today, late, lookback: 3)
      assert Decimal.equal?(width, d("0.02"))

      # Minute 200 is inside the half day, which then counts (+50%), while
      # the full days carry their minute-0 close (0%) forward to minute 200.
      assert {:ok, width} = NoiseBand.width(bars, today, 200, lookback: 3)
      assert Decimal.equal?(width, Decimal.round(Decimal.div(d("0.5"), 3), 8))
    end

    test "a minute with no trade carries the session's last earlier close forward" do
      # 09-30 has no bar at minute 5: its minute-3 close (101.5) is used.
      gappy = [
        flat(~D[2026-09-30], 0, d("100")),
        flat(~D[2026-09-30], 3, d("101.5")),
        flat(~D[2026-09-30], 9, d("90"))
      ]

      bars = gappy ++ session(~D[2026-09-29], d("101.5"))

      assert {:ok, width} = NoiseBand.width(bars, @today, 5, lookback: 2)
      assert Decimal.equal?(width, d("0.015"))
    end

    test "session open is the first regular-session bar's open; extended hours are ignored" do
      date = ~D[2026-09-30]

      bars = [
        bar(date, -30, d("50"), d("50"), d("50"), d("50")),
        bar(date, 0, d("200"), d("201"), d("199"), d("100")),
        flat(date, 5, d("202")),
        flat(date, 10, d("202")),
        bar(date, 400, d("1"), d("1"), d("1"), d("1"))
      ]

      assert {:ok, width} = NoiseBand.width(bars, @today, 5, lookback: 1)
      assert Decimal.equal?(width, d("0.01"))
    end

    test "sessions on or after today, and ones the data doesn't cover past m, don't count" do
      truncated = [flat(~D[2026-09-29], 0, d("100")), flat(~D[2026-09-29], 2, d("150"))]

      bars =
        session(@today, d("150")) ++
          session(~D[2026-10-02], d("150")) ++
          truncated ++ session(~D[2026-09-30], d("101"))

      assert {:ok, width} = NoiseBand.width(bars, @today, 5, lookback: 1)
      assert Decimal.equal?(width, d("0.01"))
      assert NoiseBand.width(bars, @today, 5, lookback: 2) == {:error, :insufficient_history}
    end

    test "a lookback that isn't a positive integer raises" do
      bars = session(~D[2026-09-30], d("101"))

      for bad <- [0, -1, "14", 1.5, nil] do
        assert_raise ArgumentError, ~r/lookback must be a positive integer/, fn ->
          NoiseBand.width(bars, @today, 5, lookback: bad)
        end
      end
    end

    test "width is rounded to 8 places" do
      bars =
        session(~D[2026-09-30], d("101")) ++
          session(~D[2026-09-29], d("101")) ++ session(~D[2026-09-28], d("102"))

      assert {:ok, width} = NoiseBand.width(bars, @today, 5, lookback: 3)
      assert width == Decimal.new("0.01333333")
    end
  end

  describe "ratio/5" do
    # today_open 101, prior_close 100, width 1%: upper band 102.01, lower 99.
    @args [Decimal.new("101"), Decimal.new("100"), Decimal.new("0.01")]

    defp gap(last), do: apply(NoiseBand, :ratio, [last | @args])

    test "gap-adjusted: exactly ±1 at the band edges" do
      assert Decimal.equal?(gap(d("102.01")), 1)
      assert Decimal.equal?(gap(d("99")), -1)
    end

    test "gap-adjusted: beyond the bands is beyond ±1" do
      assert Decimal.compare(gap(d("102.02")), 1) == :gt
      assert Decimal.compare(gap(d("98.99")), -1) == :lt
    end

    test "gap-adjusted: at a reference price is 0, inside the gap is 0" do
      assert Decimal.equal?(gap(d("101")), 0)
      assert Decimal.equal?(gap(d("100")), 0)
      assert Decimal.equal?(gap(d("100.5")), 0)
    end

    test "gap-adjusted: a gap down mirrors a gap up" do
      # today_open 100, prior_close 101: hi is still 101, lo still 100.
      assert Decimal.equal?(NoiseBand.ratio(d("102.01"), d("100"), d("101"), d("0.01")), 1)
      assert Decimal.equal?(NoiseBand.ratio(d("99"), d("100"), d("101"), d("0.01")), -1)
    end

    test "not gap-adjusted: (last / today_open − 1) / width; prior_close ignored" do
      opts = [gap_adjusted: false]

      assert Decimal.equal?(NoiseBand.ratio(d("102.01"), d("101"), nil, d("0.01"), opts), 1)
      assert Decimal.equal?(NoiseBand.ratio(d("99.99"), d("101"), nil, d("0.01"), opts), -1)

      assert Decimal.equal?(
               NoiseBand.ratio(d("100.5"), d("101"), d("100"), d("0.01"), opts),
               Decimal.new("-0.49504950")
             )
    end

    test "nil for a missing, non-positive or unparseable input" do
      assert NoiseBand.ratio(d("101"), d("101"), d("100"), d("0")) == nil
      assert NoiseBand.ratio(d("101"), d("101"), d("100"), d("-0.01")) == nil
      assert NoiseBand.ratio(nil, d("101"), d("100"), d("0.01")) == nil
      assert NoiseBand.ratio(d("101"), d("0"), d("100"), d("0.01")) == nil
      assert NoiseBand.ratio(d("101"), d("101"), nil, d("0.01")) == nil
      assert NoiseBand.ratio("x", d("101"), d("100"), d("0.01")) == nil
    end

    test "rounded to 8 places" do
      assert NoiseBand.ratio(d("103"), d("101"), d("100"), d("0.03")).exp == -8
    end
  end

  describe "minute_of_day/2" do
    test "minutes since 09:30 ET, nil outside the session" do
      assert NoiseBand.minute_of_day(~U[2026-10-01 13:30:00Z], @today) == 0
      assert NoiseBand.minute_of_day(~U[2026-10-01 13:44:59Z], @today) == 14
      assert NoiseBand.minute_of_day(~U[2026-10-01 19:59:59Z], @today) == 389
      assert NoiseBand.minute_of_day(~U[2026-10-01 13:29:59Z], @today) == nil
      assert NoiseBand.minute_of_day(~U[2026-10-01 20:00:00Z], @today) == nil
    end

    test "follows DST and half days" do
      # 2026-11-27 is EST (09:30 = 14:30 UTC) and closes at 13:00 ET.
      assert NoiseBand.minute_of_day(~U[2026-11-27 14:30:00Z], ~D[2026-11-27]) == 0
      assert NoiseBand.minute_of_day(~U[2026-11-27 17:59:00Z], ~D[2026-11-27]) == 209
      assert NoiseBand.minute_of_day(~U[2026-11-27 18:00:00Z], ~D[2026-11-27]) == nil
    end

    test "nil on a weekend or holiday" do
      assert NoiseBand.minute_of_day(~U[2026-11-26 15:00:00Z], ~D[2026-11-26]) == nil
      assert NoiseBand.minute_of_day(~U[2026-10-03 15:00:00Z], ~D[2026-10-03]) == nil
    end
  end
end
