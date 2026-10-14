defmodule TradingCore.CostModelTouchTest do
  use ExUnit.Case, async: true

  alias TradingCore.CostModel

  defp d(v), do: Decimal.new(v)

  @now ~U[2026-10-12 15:00:00Z]
  @qty Decimal.new(100)
  # 4 bps flat fallback, no impact, the 25 bps equity guard, 15s freshness
  @opts [
    slippage_bps: Decimal.new(4),
    large_position_notional_threshold: nil,
    max_spread_bps: 25,
    max_quote_age_ms: 15_000,
    now: @now
  ]
  @legacy Keyword.drop(@opts, [:max_quote_age_ms, :now])

  defp fill(price_data, side, opts \\ @opts),
    do: CostModel.simulate_fill_price(price_data, side, @qty, opts)

  # SPY-like: 0.01 wide, last one tick above the ask (the 10-12 case).
  defp spy(quote_at \\ DateTime.add(@now, -2)) do
    %{bid: d("660.10"), ask: d("660.11"), last: d("660.12"), quote_at: quote_at}
  end

  describe "fresh quote" do
    test "fills at the touch wherever last is: buy at the ask, sell at the bid" do
      assert Decimal.equal?(fill(spy(), "buy"), d("660.11"))
      assert Decimal.equal?(fill(spy(), "sell"), d("660.10"))
    end

    test "today's model charged that quote the 4 bps flat fallback" do
      # last outside [bid, ask] -> stale under the old rule: 660.12 * 4 bps
      assert Decimal.equal?(fill(spy(), "buy", @legacy), Decimal.add(d("660.12"), d("0.264048")))
    end

    test "quote_at may be Unix milliseconds" do
      ms = @now |> DateTime.add(-2) |> DateTime.to_unix(:millisecond)
      assert Decimal.equal?(fill(spy(ms), "buy"), d("660.11"))
    end

    test "exactly max_quote_age_ms old is still fresh; a millisecond more is not" do
      assert Decimal.equal?(
               fill(spy(DateTime.add(@now, -15_000, :millisecond)), "buy"),
               d("660.11")
             )

      stale = fill(spy(DateTime.add(@now, -15_001, :millisecond)), "buy")
      assert stale == fill(spy(), "buy", @legacy)
    end

    test "the impact multiplier scales the half-spread around mid" do
      # notional 66_010.50 (mid x 100) over a 33_005.25 threshold -> exactly 2x:
      # mid 660.105 +/- 2 x 0.005
      opts = Keyword.put(@opts, :large_position_notional_threshold, d("33005.25"))
      assert Decimal.equal?(fill(spy(), "buy", opts), d("660.115"))
      assert Decimal.equal?(fill(spy(), "sell", opts), d("660.095"))
    end

    test "float prices are coerced" do
      q = %{bid: 660.10, ask: 660.11, last: 660.12, quote_at: DateTime.add(@now, -1)}
      assert Decimal.equal?(fill(q, "buy"), d("660.11"))
    end
  end

  describe "wide fresh quotes are trusted, never charged less than a tight one" do
    test "a real 36 bps quote fills at the touch, not at the 4 bps fallback" do
      # FNV-like: 199.64 / 200.36, half-spread 0.36 = 18 bps of mid
      q = %{
        bid: d("199.64"),
        ask: d("200.36"),
        last: d("200.00"),
        quote_at: DateTime.add(@now, -1)
      }

      assert Decimal.equal?(fill(q, "buy"), d("200.36"))
      assert Decimal.equal?(fill(q, "sell"), d("199.64"))

      # the old path dropped it to 4 bps of last
      assert Decimal.equal?(fill(q, "buy", @legacy), d("200.08"))
    end

    test "beyond max_fresh_spread_bps the half-spread is capped, still above the fallback" do
      # 190 / 210 around mid 200: 1000 bps wide; default cap 100 bps -> half 1.00
      q = %{bid: d("190"), ask: d("210"), last: d("200"), quote_at: DateTime.add(@now, -1)}
      assert Decimal.equal?(fill(q, "buy"), d("201.00"))

      assert Decimal.equal?(
               fill(q, "buy", Keyword.put(@opts, :max_fresh_spread_bps, 400)),
               d("204.00")
             )
    end

    test "with no stale guard (max_spread_bps unset) the fresh cap is off too" do
      q = %{bid: d("190"), ask: d("210"), last: d("200"), quote_at: DateTime.add(@now, -1)}
      assert Decimal.equal?(fill(q, "buy", Keyword.delete(@opts, :max_spread_bps)), d("210"))
    end
  end

  describe "falls back to today's behaviour" do
    test "a stale quote_at" do
      q = spy(DateTime.add(@now, -60))
      assert fill(q, "buy") == fill(q, "buy", @legacy)
    end

    test "no quote_at, or no :max_quote_age_ms" do
      q = Map.delete(spy(), :quote_at)
      assert fill(q, "buy") == fill(q, "buy", @legacy)

      assert fill(spy(), "buy", Keyword.delete(@opts, :max_quote_age_ms)) ==
               fill(spy(), "buy", @legacy)
    end

    test "crossed, one-sided or non-positive quotes" do
      fresh = DateTime.add(@now, -1)

      for q <- [
            %{bid: d("660.12"), ask: d("660.10"), last: d("660.11"), quote_at: fresh},
            %{bid: nil, ask: d("660.11"), last: d("660.11"), quote_at: fresh},
            %{bid: d("660.10"), ask: nil, last: d("660.11"), quote_at: fresh},
            %{bid: d("0"), ask: d("660.11"), last: d("660.11"), quote_at: fresh}
          ] do
        assert fill(q, "buy") == fill(q, "buy", @legacy), inspect(q)
      end
    end

    test "an unparseable quote_at" do
      q = %{spy() | quote_at: "2026-10-12T15:00:00Z"}
      assert fill(q, "buy") == fill(q, "buy", @legacy)
    end
  end
end
