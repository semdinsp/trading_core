defmodule TradingCore.Polygon.UnderlyingFeaturesTest do
  use ExUnit.Case, async: true

  alias TradingCore.Polygon.UnderlyingFeatures, as: F

  # 2026-09-23 14:00:00Z = 10:00 ET, inside the regular session.
  @t0 DateTime.to_unix(~U[2026-09-23 14:00:00Z], :millisecond)

  defp trade(f, price, at, size \\ nil) do
    data = %{last: Decimal.new(price), timestamp: DateTime.from_unix!(at, :millisecond)}
    data = if size, do: Map.put(data, :size, Decimal.new(size)), else: data
    F.apply_trade(f, data, at)
  end

  defp quote(f, bid, ask, bs, as, at) do
    F.apply_quote(
      f,
      %{
        bid: Decimal.new(bid),
        ask: Decimal.new(ask),
        bid_size: bs && Decimal.new(bs),
        ask_size: as && Decimal.new(as)
      },
      at
    )
  end

  describe "quote features" do
    test "spread and imbalance from a sized quote" do
      snap = F.new() |> quote("100.00", "100.10", "300", "100", @t0) |> F.to_snapshot(@t0)

      assert_in_delta snap["run_poly_spread_bps"], 9.995, 0.01
      assert_in_delta snap["run_poly_imbalance"], 0.5, 1.0e-9
      assert_in_delta snap["run_poly_imbalance_ema"], 0.5, 1.0e-9
    end

    # Unknown is not zero: a 0.0 here would satisfy `imbalance < 0.1`
    # on no information at all.
    test "a quote with unknown sizes reports spread but NO imbalance" do
      snap = F.new() |> quote("100.00", "100.10", nil, nil, @t0) |> F.to_snapshot(@t0)

      assert Map.has_key?(snap, "run_poly_spread_bps")
      refute Map.has_key?(snap, "run_poly_imbalance")
      refute Map.has_key?(snap, "run_poly_imbalance_ema")
    end

    test "0/0 sizes report no imbalance rather than raising" do
      snap = F.new() |> quote("100.00", "100.10", "0", "0", @t0) |> F.to_snapshot(@t0)
      refute Map.has_key?(snap, "run_poly_imbalance")
    end

    test "a size-less quote does not drag the EMA toward zero" do
      snap =
        F.new()
        |> quote("100.00", "100.10", "300", "100", @t0)
        |> quote("100.00", "100.10", nil, nil, @t0 + 5_000)
        |> F.to_snapshot(@t0 + 5_000)

      assert_in_delta snap["run_poly_imbalance_ema"], 0.5, 1.0e-9
    end

    # Fresh size-less quotes must not keep an old EMA looking current.
    test "the EMA goes absent once the last SIZED quote is stale" do
      snap =
        F.new()
        |> quote("100.00", "100.10", "300", "100", @t0)
        |> quote("100.00", "100.10", nil, nil, @t0 + 60_000)
        |> F.to_snapshot(@t0 + 60_000)

      assert Map.has_key?(snap, "run_poly_spread_bps")
      refute Map.has_key?(snap, "run_poly_imbalance_ema")
    end

    # Decay runs from the last sized quote, not the last quote of any kind.
    test "size-less quotes don't shorten the decay of the next sized one" do
      snap =
        F.new()
        |> quote("100.00", "100.10", "300", "100", @t0)
        |> quote("100.00", "100.10", nil, nil, @t0 + 59_900)
        |> quote("100.00", "100.10", "100", "300", @t0 + 60_000)
        |> F.to_snapshot(@t0 + 60_000)

      # 60s at a 10s time constant: almost fully the new -0.5 reading.
      assert snap["run_poly_imbalance_ema"] < -0.49
    end

    test "EMA moves partway toward a new reading" do
      snap =
        F.new()
        |> quote("100.00", "100.10", "300", "100", @t0)
        |> quote("100.00", "100.10", "100", "300", @t0 + 10_000)
        |> F.to_snapshot(@t0 + 10_000)

      ema = snap["run_poly_imbalance_ema"]
      assert ema < 0.5 and ema > -0.5
    end

    test "stale quote features are omitted" do
      snap =
        F.new() |> quote("100.00", "100.10", "300", "100", @t0) |> F.to_snapshot(@t0 + 31_000)

      assert snap == %{}
    end

    # Late delivery (a hub catching up after a reconnect) must not look
    # fresh: the hub's own stamp dates the value, not receive time.
    test "a quote stamped 60s ago is stale even if it arrived just now" do
      data = %{
        bid: Decimal.new("100.00"),
        ask: Decimal.new("100.10"),
        bid_size: Decimal.new("1"),
        ask_size: Decimal.new("1"),
        timestamp: DateTime.from_unix!(@t0 - 60_000, :millisecond)
      }

      assert F.new() |> F.apply_quote(data, @t0) |> F.to_snapshot(@t0) == %{}
    end

    test "a crossed or one-sided quote is ignored" do
      assert F.new() |> quote("100.10", "100.00", "1", "1", @t0) |> F.to_snapshot(@t0) == %{}
      assert F.new() |> quote("0", "100.00", "1", "1", @t0) |> F.to_snapshot(@t0) == %{}
    end
  end

  describe "returns" do
    test "1m return from the sample at the window start" do
      f =
        Enum.reduce(0..60, F.new(), fn s, f ->
          trade(f, if(s == 60, do: "101.00", else: "100.00"), @t0 + s * 1_000)
        end)

      snap = F.to_snapshot(f, @t0 + 60_000)
      assert_in_delta snap["run_poly_ret_1m_bps"], 100.0, 1.0e-6
      refute Map.has_key?(snap, "run_poly_ret_5m_bps")
    end

    test "no return until the buffer reaches back to the window start" do
      f = F.new() |> trade("100.00", @t0) |> trade("101.00", @t0 + 30_000)
      refute Map.has_key?(F.to_snapshot(f, @t0 + 30_000), "run_poly_ret_1m_bps")
    end

    # A feed gap must not become a return over a silently longer window.
    test "no return when the nearest older sample is far before the window" do
      f = F.new() |> trade("100.00", @t0) |> trade("101.00", @t0 + 200_000)
      refute Map.has_key?(F.to_snapshot(f, @t0 + 200_000), "run_poly_ret_1m_bps")
    end

    test "samples at most once per second" do
      f = Enum.reduce(0..99, F.new(), fn ms, f -> trade(f, "100.00", @t0 + ms) end)
      assert :queue.len(f.samples) == 1
    end
  end

  describe "vwap" do
    test "deviation from the regular-session VWAP" do
      snap =
        F.new()
        |> trade("100.00", @t0, "100")
        |> trade("102.00", @t0 + 1_000, "100")
        |> F.to_snapshot(@t0 + 1_000)

      # VWAP 101, last 102
      assert_in_delta snap["run_poly_vwap_dev_bps"], 99.0099, 0.001
    end

    test "pre-market prints are excluded" do
      pre = DateTime.to_unix(~U[2026-09-23 12:00:00Z], :millisecond)
      snap = F.new() |> trade("100.00", pre, "100") |> F.to_snapshot(pre)
      refute Map.has_key?(snap, "run_poly_vwap_dev_bps")
    end

    test "unsized trades don't contribute" do
      snap = F.new() |> trade("100.00", @t0) |> F.to_snapshot(@t0)
      assert snap["run_poly_last"] == 100.0
      refute Map.has_key?(snap, "run_poly_vwap_dev_bps")
    end

    test "yesterday's VWAP is not reported today" do
      next_day = @t0 + 86_400_000
      f = F.new() |> trade("100.00", @t0, "100")
      # A fresh unsized trade the next morning keeps last-trade fresh.
      snap = f |> trade("100.00", next_day) |> F.to_snapshot(next_day)
      refute Map.has_key?(snap, "run_poly_vwap_dev_bps")
    end
  end

  describe "volume" do
    defp bars(f, volumes) do
      volumes
      |> Enum.with_index()
      |> Enum.reduce(f, fn {v, i}, f -> F.apply_aggregate(f, %{volume: v}, @t0 + i * 60_000) end)
    end

    test "relative volume against prior bars" do
      f = bars(F.new(), [100, 100, 100, 100, 100, 300])
      snap = F.to_snapshot(f, @t0 + 5 * 60_000)

      assert snap["run_poly_minute_volume"] == 300.0
      assert_in_delta snap["run_poly_rel_volume"], 3.0, 1.0e-9
    end

    test "no relative volume before 5 prior bars" do
      f = bars(F.new(), [100, 100, 100, 100, 300])
      snap = F.to_snapshot(f, @t0 + 4 * 60_000)

      assert Map.has_key?(snap, "run_poly_minute_volume")
      refute Map.has_key?(snap, "run_poly_rel_volume")
    end

    test "all-zero prior bars give no relative volume" do
      f = bars(F.new(), [0, 0, 0, 0, 0, 300])
      refute Map.has_key?(F.to_snapshot(f, @t0 + 5 * 60_000), "run_poly_rel_volume")
    end

    test "history is capped at 20 prior bars" do
      f = bars(F.new(), List.duplicate(1, 30))
      assert length(f.prior_bars) == 20
    end
  end
end
