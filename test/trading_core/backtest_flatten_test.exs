defmodule TradingCore.BacktestFlattenTest do
  use ExUnit.Case, async: true

  alias TradingCore.Backtest

  # Enters long whenever the close is above 100; the stop/target are far
  # away, so only the flatten (or end_of_data) closes a run.
  @strategy %{
    "direction" => "long",
    "rules" => %{
      "entry" => %{"signal" => "close_price", "op" => "gt", "value" => 100},
      "exit" => nil
    },
    "params" => %{
      "risk_controls" => %{
        "method" => "percent_of_entry",
        "stop_loss_percent" => 50,
        "take_profit_percent" => 50
      }
    },
    "position_sizing" => %{"method" => "fixed_qty", "qty" => 1}
  }

  @specs %{"close_price" => %{kind: :price}}
  @flatten [signal_specs: @specs, flatten_at: ~T[15:55:00]]

  defp d(v) when is_integer(v), do: Decimal.new(v)
  defp d(v) when is_binary(v), do: Decimal.new(v)

  defp et(date, time),
    do: date |> DateTime.new!(time, "America/New_York") |> DateTime.shift_zone!("Etc/UTC")

  # A minute bar at `time` ET on `date`; open/high/low/close all `close`
  # unless `open` is given.
  defp bar(date, time, close, open \\ nil) do
    close = d(close)
    open = if open, do: d(open), else: close

    %{
      ts: et(date, time),
      open: open,
      high: Decimal.max(open, close),
      low: Decimal.min(open, close),
      close: close,
      volume: d(1000)
    }
  end

  # Minute bars from `from` to `to` (inclusive) ET on `date`, all at `price`.
  defp minutes(date, from, to, price) do
    from
    |> Stream.iterate(&Time.add(&1, 60))
    |> Enum.take_while(&(Time.compare(&1, to) != :gt))
    |> Enum.map(&bar(date, &1, price))
  end

  defp run(bars, opts), do: Backtest.run(@strategy, %{"SPY" => bars}, opts)

  @thu ~D[2026-10-01]
  @fri ~D[2026-10-02]

  describe "flatten_at" do
    test "a position open at 15:54 is flattened at the 15:55 bar's close" do
      bars =
        [bar(@thu, ~T[15:50:00], 99), bar(@thu, ~T[15:51:00], 101)] ++
          minutes(@thu, ~T[15:52:00], ~T[15:54:00], 102) ++
          [bar(@thu, ~T[15:55:00], 104, 103)] ++ minutes(@thu, ~T[15:56:00], ~T[15:59:00], 105)

      assert {:ok, [run]} = run(bars, @flatten)

      # signal on the 15:51 close, filled at the 15:52 open
      assert run.entry_at == et(@thu, ~T[15:52:00])
      assert run.exit_at == et(@thu, ~T[15:55:00])
      assert Decimal.equal?(run.exit_price, 104)
      assert run.exit_reason == "eod_flatten"
    end

    test "no re-entry after the flatten, then a normal entry the next morning" do
      bars =
        minutes(@thu, ~T[15:40:00], ~T[15:59:00], 101) ++
          [bar(@fri, ~T[09:30:00], 101)] ++ minutes(@fri, ~T[09:31:00], ~T[09:40:00], 102)

      assert {:ok, [first, second]} = run(bars, @flatten)

      assert first.exit_reason == "eod_flatten"
      assert first.exit_at == et(@thu, ~T[15:55:00])

      # Nothing between 15:55 Thursday and the open; the 09:30 signal
      # fills at 09:31.
      assert second.entry_at == et(@fri, ~T[09:31:00])
      assert second.exit_reason == "end_of_data"
    end

    test "a signal at 15:54 doesn't fill into the 15:55 window" do
      bars =
        minutes(@thu, ~T[15:50:00], ~T[15:53:00], 99) ++
          minutes(@thu, ~T[15:54:00], ~T[15:59:00], 101)

      assert run(bars, @flatten) == {:ok, []}
    end

    test "no entries pre-market or across the overnight gap" do
      bars =
        (minutes(@fri, ~T[08:00:00], ~T[09:29:00], 101) ++
           [bar(@thu, ~T[15:59:00], 101)])
        |> Enum.sort_by(& &1.ts, DateTime)

      assert run(bars, @flatten) == {:ok, []}
    end

    test "DST: flattens at 15:55 ET on both sides of the March and November changes" do
      for date <- [~D[2026-03-06], ~D[2026-03-09], ~D[2026-10-30], ~D[2026-11-02]] do
        bars = minutes(date, ~T[15:45:00], ~T[15:59:00], 101)

        assert {:ok, [run]} = run(bars, @flatten)
        assert run.exit_reason == "eod_flatten", "#{date}"
        assert run.exit_at == et(date, ~T[15:55:00]), "#{date}"
      end

      # The UTC times really differ across each change.
      assert et(~D[2026-03-06], ~T[15:55:00]).hour == 20
      assert et(~D[2026-03-09], ~T[15:55:00]).hour == 19
      assert et(~D[2026-10-30], ~T[15:55:00]).hour == 19
      assert et(~D[2026-11-02], ~T[15:55:00]).hour == 20
    end

    test "a half day flattens the same distance before its 13:00 close" do
      half_day = ~D[2026-11-27]
      bars = minutes(half_day, ~T[12:40:00], ~T[12:59:00], 101)

      assert {:ok, [run]} = run(bars, @flatten)
      assert run.exit_at == et(half_day, ~T[12:55:00])
      assert run.exit_reason == "eod_flatten"
    end

    test "safety net: a data gap past the cutoff still flattens on the session's last bar" do
      bars =
        minutes(@thu, ~T[15:20:00], ~T[15:30:00], 101) ++
          minutes(@fri, ~T[09:30:00], ~T[09:32:00], 99)

      assert {:ok, [run]} = run(bars, @flatten)
      assert run.exit_at == et(@thu, ~T[15:30:00])
      assert run.exit_reason == "eod_flatten"
    end

    test "an intrabar stop on the flatten bar wins over the flatten" do
      strategy =
        put_in(@strategy, ["params", "risk_controls"], %{
          "method" => "percent_of_entry",
          "stop_loss_percent" => 1,
          "take_profit_percent" => 50
        })

      # entry fills at 101 (15:52 open); the 15:55 bar trades down to 99,
      # through the 99.99 stop, before closing at 100.5.
      flatten_bar = %{bar(@thu, ~T[15:55:00], "100.5", 101) | low: d(99)}

      bars =
        [bar(@thu, ~T[15:50:00], 99), bar(@thu, ~T[15:51:00], 101)] ++
          minutes(@thu, ~T[15:52:00], ~T[15:54:00], 101) ++ [flatten_bar]

      assert {:ok, [run]} =
               Backtest.run(strategy, %{"SPY" => bars}, @flatten ++ [intrabar: true])

      assert run.exit_reason == "stopped_out"
      assert run.exit_at == et(@thu, ~T[15:55:00])
    end

    test "absent (or nil) behaves exactly as before: held overnight to end_of_data" do
      bars =
        minutes(@thu, ~T[15:40:00], ~T[15:59:00], 101) ++
          minutes(@fri, ~T[09:30:00], ~T[09:35:00], 102)

      assert {:ok, [run]} = without = run(bars, signal_specs: @specs)
      assert run(bars, signal_specs: @specs, flatten_at: nil) == without

      assert run.entry_at == et(@thu, ~T[15:41:00])
      assert run.exit_at == et(@fri, ~T[09:35:00])
      assert run.exit_reason == "end_of_data"
    end

    test "an invalid flatten_at is an error" do
      for bad <- ["15:55", 1555, ~U[2026-10-01 19:55:00Z]] do
        assert run([], signal_specs: @specs, flatten_at: bad) == {:error, :invalid_flatten_at}
      end
    end
  end

  describe "volatility_target daily_vol on intraday bars" do
    # Four trading days; each day's regular-session closes end at the
    # given daily close, with pre- and post-market bars that must not
    # count.
    @days [
      {~D[2026-09-28], 100},
      {~D[2026-09-29], 102},
      {~D[2026-09-30], 99},
      {~D[2026-10-01], 105}
    ]

    defp intraday_history do
      Enum.flat_map(@days, fn {date, close} ->
        [bar(date, ~T[08:00:00], 500)] ++
          minutes(date, ~T[09:30:00], ~T[15:58:00], close - 1) ++
          [bar(date, ~T[15:59:00], close), bar(date, ~T[19:59:00], 1)]
      end)
    end

    test "uses one regular-session close per ET day, not one per bar" do
      bars = intraday_history()

      # the 15:59 bar of the last day
      index = length(bars) - 2

      daily_bars =
        Enum.map(@days, fn {date, close} ->
          %{bar(date, ~T[20:00:00], close) | ts: et(date, ~T[20:00:00])}
        end)

      assert {:ok, minute_vol} = Backtest.estimate_daily_vol(bars, index, 20)
      assert {:ok, daily_vol} = Backtest.estimate_daily_vol(daily_bars, 3, 20)
      assert Decimal.equal?(minute_vol, daily_vol)
    end

    test "today's close so far is the bar at index" do
      bars = intraday_history()
      last_day = ~D[2026-10-01]
      noon = Enum.find_index(bars, &(&1.ts == et(last_day, ~T[12:00:00])))

      # At noon on the last day its close so far is 104 (the 09:30-15:58 bars).
      expected_bars =
        Enum.map(
          [{~D[2026-09-28], 100}, {~D[2026-09-29], 102}, {~D[2026-09-30], 99}, {last_day, 104}],
          fn {date, close} ->
            bar(date, ~T[20:00:00], close)
          end
        )

      assert {:ok, at_noon} = Backtest.estimate_daily_vol(bars, noon, 20)
      assert {:ok, expected} = Backtest.estimate_daily_vol(expected_bars, 3, 20)
      assert Decimal.equal?(at_noon, expected)
    end

    test "fewer than two trading days is insufficient, however many minute bars" do
      bars = minutes(@thu, ~T[09:30:00], ~T[15:59:00], 101)
      assert Backtest.estimate_daily_vol(bars, length(bars) - 1, 20) == :insufficient_data
    end
  end
end
