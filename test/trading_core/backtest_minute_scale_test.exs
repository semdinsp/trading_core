defmodule TradingCore.BacktestMinuteScaleTest do
  use ExUnit.Case, async: true

  alias TradingCore.{Backtest, PositionSizing, Volatility}

  defp d(v) when is_integer(v), do: Decimal.new(v)
  defp d(v) when is_float(v), do: Decimal.from_float(v)
  defp d(%Decimal{} = v), do: v

  defp et(date, time),
    do: date |> DateTime.new!(time, "America/New_York") |> DateTime.shift_zone!("Etc/UTC")

  defp bar(ts, close, open \\ nil) do
    close = d(close)
    open = if open, do: d(open), else: close

    %{
      ts: ts,
      open: open,
      high: Decimal.max(open, close),
      low: Decimal.min(open, close),
      close: close,
      volume: d(1000)
    }
  end

  defp entry_strategy(entry, exit \\ nil, extra \\ %{}) do
    Map.merge(
      %{
        "direction" => "long",
        "rules" => %{"entry" => entry, "exit" => exit},
        "params" => %{
          "risk_controls" => %{
            "method" => "percent_of_entry",
            "stop_loss_percent" => 10,
            "take_profit_percent" => 20
          }
        },
        "position_sizing" => %{"method" => "fixed_qty", "qty" => 1}
      },
      extra
    )
  end

  @close_gt_99 %{"signal" => "close_price", "op" => "gt", "value" => 99}

  describe "entry_stop_loss_price / entry_take_profit_price" do
    test "report the levels set at entry, not where a ratchet moved them" do
      strategy =
        entry_strategy(@close_gt_99, nil, %{
          "params" => %{
            "risk_controls" => %{
              "method" => "percent_of_entry",
              "stop_loss_percent" => 10,
              "take_profit_percent" => 20
            },
            "exit_strategy" => %{"method" => "ratchet", "trigger_pct" => 5, "lock_pct" => 2}
          }
        })

      day = fn n -> DateTime.new!(Date.add(~D[2026-09-01], n), ~T[20:00:00], "Etc/UTC") end

      bars = [
        # signal on close 100, fills at the next open (100): stop 90, target 120
        bar(day.(0), 100),
        # close 106 trips the ratchet: stop -> 102, target cleared
        bar(day.(1), 106, 100),
        # close 101 is through the ratcheted stop; fills at the next open
        bar(day.(2), 101, 106),
        bar(day.(3), 101)
      ]

      assert {:ok, [run]} =
               Backtest.run(strategy, %{"SPY" => bars},
                 signal_specs: %{"close_price" => %{kind: :price}}
               )

      assert run.exit_reason == "stopped_out"
      assert Decimal.equal?(run.entry_stop_loss_price, 90)
      assert Decimal.equal?(run.entry_take_profit_price, 120)
    end
  end

  describe "global series sampling" do
    @vix_gt_20 %{"signal" => "vix", "op" => "gt", "value" => 20}
    @vix_le_20 %{"signal" => "vix", "op" => "lte", "value" => 20}
    @vix_spec %{"vix" => %{kind: :series}}

    test "each bar sees the latest series value at or before it" do
      base = ~U[2026-10-01 14:00:00Z]
      at = fn seconds -> DateTime.add(base, seconds) end
      bars = Enum.map(0..9, &bar(at.(&1 * 60), 100))

      vix = [
        {at.(-300), d(15)},
        # exactly on bar 3's ts: bar 3 sees it
        {at.(180), d(25)},
        # between bars 5 and 6: bar 6 is the first to see it
        {at.(330), d(10)}
      ]

      assert {:ok, [run]} =
               Backtest.run(entry_strategy(@vix_gt_20, @vix_le_20), %{"SPY" => bars},
                 signal_specs: @vix_spec,
                 literal_series: %{"vix" => vix}
               )

      # entry signal on bar 3, fills at bar 4; exit signal on bar 6, fills at bar 7
      assert run.entry_at == at.(240)
      assert run.exit_at == at.(420)
      assert run.exit_reason == "rule_exit"
    end

    test "an irregular series gives the same runs as one pre-sampled on the bar times" do
      :rand.seed(:exsss, {7, 8, 9})
      base = ~U[2026-10-01 13:30:00Z]
      bars = Enum.map(0..1999, &bar(DateTime.add(base, &1 * 60), 100))

      vix =
        1..700
        |> Enum.map(fn _ -> :rand.uniform(2000 * 60) - 600 end)
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.map(&{DateTime.add(base, &1), d(:rand.uniform(40))})

      # Brute-force LOCF, the old sample_at/2: latest entry at or before ts.
      locf = fn ts ->
        vix
        |> Enum.take_while(fn {entry_ts, _} -> DateTime.compare(entry_ts, ts) != :gt end)
        |> List.last()
      end

      aligned =
        Enum.flat_map(bars, fn %{ts: ts} ->
          case locf.(ts) do
            nil -> []
            {_ts, value} -> [{ts, value}]
          end
        end)

      run_with = fn series ->
        Backtest.run(entry_strategy(@vix_gt_20, @vix_le_20), %{"SPY" => bars},
          signal_specs: @vix_spec,
          literal_series: %{"vix" => series}
        )
      end

      assert {:ok, runs} = run_with.(vix)
      assert length(runs) > 20
      assert run_with.(aligned) == {:ok, runs}
    end
  end

  describe "sizing_vol: :ewma" do
    # Twelve trading days of regular-session minute bars, each day closing
    # at its daily close; the entry fires at noon on the last day.
    @closes [100, 103, 99, 104, 101, 106, 102, 98, 105, 107, 103, 109]

    defp days do
      ~D[2026-09-14]
      |> Stream.iterate(&Date.add(&1, 1))
      |> Stream.filter(&(TradingCore.Intraday.RegularSession.bounds(&1) != :error))
      |> Enum.take(length(@closes))
    end

    defp fixture do
      days = days()
      {prior_days, [today]} = Enum.split(days, -1)

      prior_bars =
        prior_days
        |> Enum.zip(@closes)
        |> Enum.flat_map(fn {date, close} ->
          for minute <- [0, 60, 389],
              do: bar(DateTime.add(et(date, ~T[09:30:00]), minute * 60), close)
        end)

      today_bars = [
        bar(et(today, ~T[09:30:00]), 108),
        # the signal bar: today's close so far is 210
        bar(et(today, ~T[12:00:00]), 210),
        # fill bar
        bar(et(today, ~T[12:01:00]), 211, 212)
      ]

      {prior_days, today, prior_bars ++ today_bars}
    end

    defp sizing_strategy do
      %{
        entry_strategy(%{"signal" => "close_price", "op" => "gt", "value" => 200})
        | "position_sizing" => %{"method" => "volatility_target"}
      }
    end

    defp opts(extra) do
      [signal_specs: %{"close_price" => %{kind: :price}}, target_dollar_volatility: d(1000)] ++
        extra
    end

    test "sizes with the hub's EWMA over the daily closes" do
      {prior_days, today, bars} = fixture()

      daily =
        Enum.zip(prior_days, Enum.drop(@closes, -1))
        |> Enum.map(fn {date, close} -> %{ts: date, close: d(close)} end)
        |> Kernel.++([%{ts: today, close: d(210)}])

      {:ok, vol} = Volatility.ewma_daily_vol(daily, as_of: today, lookback_days: 14, lambda: 0.94)

      {:ok, expected_qty} =
        PositionSizing.calculate_qty(%{"method" => "volatility_target"}, %{
          daily_vol: vol,
          price: d(212),
          target_dollar_volatility: d(1000),
          fractional_shares_enabled: true
        })

      assert {:ok, [run]} =
               Backtest.run(sizing_strategy(), %{"SPY" => bars}, opts(sizing_vol: :ewma))

      assert Decimal.equal?(run.qty, expected_qty)

      # and it is not the stdev estimate
      assert {:ok, [stdev_run]} = Backtest.run(sizing_strategy(), %{"SPY" => bars}, opts([]))
      refute Decimal.equal?(stdev_run.qty, run.qty)
    end

    test "lookback and lambda are options" do
      {_prior, _today, bars} = fixture()

      assert {:ok, [default]} =
               Backtest.run(sizing_strategy(), %{"SPY" => bars}, opts(sizing_vol: :ewma))

      assert {:ok, [longer]} =
               Backtest.run(
                 sizing_strategy(),
                 %{"SPY" => bars},
                 opts(sizing_vol: :ewma, sizing_vol_lookback_days: 30, sizing_vol_lambda: 0.97)
               )

      refute Decimal.equal?(default.qty, longer.qty)
    end

    test "default is the 20-day stdev, same as sizing_vol: :stdev" do
      {_prior, _today, bars} = fixture()

      assert Backtest.run(sizing_strategy(), %{"SPY" => bars}, opts([])) ==
               Backtest.run(sizing_strategy(), %{"SPY" => bars}, opts(sizing_vol: :stdev))
    end

    test "an invalid value is an error" do
      assert Backtest.run(sizing_strategy(), %{}, opts(sizing_vol: :garch)) ==
               {:error, :invalid_sizing_vol}
    end
  end

  @tag timeout: 120_000
  test "performance: 30k minute bars with three global series run in a few seconds" do
    :rand.seed(:exsss, {4, 5, 6})

    days =
      ~D[2025-02-03]
      |> Stream.iterate(&Date.add(&1, 1))
      |> Stream.filter(&(TradingCore.Intraday.RegularSession.bounds(&1) != :error))
      |> Enum.take(78)

    {bars, _price} =
      Enum.flat_map_reduce(days, 100.0, fn date, price ->
        open = et(date, ~T[09:30:00])

        Enum.map_reduce(0..389, price, fn minute, price ->
          price = price * (1 + 0.0008 * :rand.normal())
          {bar(DateTime.add(open, minute * 60), Float.round(price, 2)), price}
        end)
      end)

    series = fn -> Enum.map(bars, &{&1.ts, d(:rand.uniform(40))}) end
    literal_series = %{"vix" => series.(), "tick" => series.(), "breadth" => series.()}

    strategy =
      entry_strategy(
        %{
          "all" => [
            %{"signal" => "vix", "op" => "gt", "value" => 10},
            %{"signal" => "tick", "op" => "gt", "value" => 5},
            %{"signal" => "breadth", "op" => "gt", "value" => 5}
          ]
        },
        nil,
        %{
          "params" => %{
            "risk_controls" => %{
              "method" => "percent_of_entry",
              "stop_loss_percent" => 0.3,
              "take_profit_percent" => 0.3
            }
          },
          "position_sizing" => %{"method" => "volatility_target"}
        }
      )

    specs = %{
      "vix" => %{kind: :series},
      "tick" => %{kind: :series},
      "breadth" => %{kind: :series}
    }

    {micros, {:ok, runs}} =
      :timer.tc(fn ->
        Backtest.run(strategy, %{"SPY" => bars},
          signal_specs: specs,
          literal_series: literal_series,
          target_dollar_volatility: d(1000),
          sizing_vol: :ewma,
          flatten_at: ~T[15:55:00],
          intrabar: true
        )
      end)

    assert length(bars) > 30_000
    assert length(runs) > 100
    assert div(micros, 1000) < 10_000, "took #{div(micros, 1000)}ms"
  end
end
