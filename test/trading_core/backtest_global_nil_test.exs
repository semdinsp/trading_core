defmodule TradingCore.BacktestGlobalNilTest do
  use ExUnit.Case, async: true

  alias TradingCore.Backtest

  @base ~U[2026-09-01 20:00:00Z]

  defp d(v) when is_integer(v), do: Decimal.new(v)
  defp d(v) when is_binary(v), do: Decimal.new(v)

  defp at(day), do: DateTime.add(@base, day * 86_400)

  defp day_bar(day, close) do
    close = d(close)
    %{ts: at(day), open: close, high: close, low: close, close: close, volume: d(1000)}
  end

  defp strategy(signal) do
    %{
      "direction" => "long",
      "rules" => %{
        "entry" => %{"signal" => signal, "op" => "gt", "value" => -1_000_000},
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
  end

  defp spy_bars, do: Enum.map(0..9, &day_bar(&1, 100))

  test "a :vwap base whose bars carry no :vwap: percent_deviation is nil, no crash" do
    # trading_backtest's repro: Polygon day files have no VWAP.
    qqq = Enum.map(0..9, &day_bar(&1, 400))

    specs = %{
      "qqq_close" => %{kind: :price, symbol: "QQQ", scope: :global},
      "qqq_vwap" => %{kind: :vwap, symbol: "QQQ", scope: :global},
      "qqq_vs_vwap" => %{kind: :percent_deviation, value: "qqq_close", reference: "qqq_vwap"}
    }

    assert Backtest.run(strategy("qqq_vs_vwap"), %{"SPY" => spy_bars(), "QQQ" => qqq},
             signal_specs: specs
           ) == {:ok, []}
  end

  # The reference series starts on day 5; before that the merged pair has
  # a nil reference. Each two-input kind must yield "no value" there and
  # a value once both exist, so the entry fires on day 5 and fills day 6.
  @value Enum.map(
           0..9,
           &{DateTime.add(~U[2026-09-01 20:00:00Z], &1 * 86_400), Decimal.new(10 + &1)}
         )
  @late_reference Enum.map(
                    5..9,
                    &{DateTime.add(~U[2026-09-01 20:00:00Z], &1 * 86_400), Decimal.new(5)}
                  )

  for {kind, spec} <- [
        percent_deviation: %{kind: :percent_deviation, value: "a", reference: "b"},
        ratio: %{kind: :ratio, value: "a", reference: "b"},
        spread_zscore: %{kind: :spread_zscore, value: "a", reference: "b"},
        regime: %{
          kind: :regime,
          direction: "a",
          gate: "b",
          tick_deadband: Decimal.new(0),
          vix_gate_zscore: Decimal.new(100)
        }
      ] do
    @kind kind
    @signal_spec spec
    test "#{kind}: nil on one side before it starts is no value, not a crash" do
      specs = %{"a" => %{kind: :series}, "b" => %{kind: :series}, "x" => @signal_spec}

      result =
        Backtest.run(strategy("x"), %{"SPY" => spy_bars()},
          signal_specs: specs,
          literal_series: %{"a" => @value, "b" => @late_reference}
        )

      assert {:ok, runs} = result

      # spread_zscore needs a few samples before it has a z-score at all.
      if @kind != :spread_zscore do
        assert [%{entry_at: entry_at}] = runs
        assert entry_at == at(6)
      end
    end
  end

  test "nil entries in a literal series don't reach a single-input kind" do
    series =
      Enum.map(0..9, fn day ->
        {at(day), if(rem(day, 3) == 0, do: nil, else: d(10 + day))}
      end)

    specs = %{
      "a" => %{kind: :series},
      "a_slope" => %{kind: :derivative, parent: "a", window_ms: :timer.hours(72)},
      "a_z" => %{kind: :self_zscore, parent: "a", window_ms: :timer.hours(240)}
    }

    for signal <- ["a_slope", "a_z"] do
      assert {:ok, _runs} =
               Backtest.run(strategy(signal), %{"SPY" => spy_bars()},
                 signal_specs: specs,
                 literal_series: %{"a" => series}
               )
    end
  end
end
