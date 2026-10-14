defmodule TradingCore.MicrostructureTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias TradingCore.Microstructure, as: M
  alias TradingCore.Signal.{Compute, Spec}

  defp d(v), do: Decimal.new(v)

  defp q(bid, ask, bid_size, ask_size),
    do: %{
      bid: d(bid),
      ask: d(ask),
      bid_size: bid_size && d(bid_size),
      ask_size: ask_size && d(ask_size)
    }

  describe "ofi_contribution/3" do
    test "bid side: up adds the new size, unchanged adds the change, down removes the old" do
      # asks unchanged with unchanged size, so only the bid side moves
      assert Decimal.equal?(
               M.ofi_contribution(q("10.00", "10.02", 100, 50), q("10.01", "10.02", 70, 50)),
               70
             )

      assert Decimal.equal?(
               M.ofi_contribution(q("10.00", "10.02", 100, 50), q("10.00", "10.02", 130, 50)),
               30
             )

      assert Decimal.equal?(
               M.ofi_contribution(q("10.00", "10.02", 100, 50), q("9.99", "10.02", 80, 50)),
               -100
             )
    end

    test "ask side: down sells the new size, unchanged adds the decrease, up adds the old" do
      assert Decimal.equal?(
               M.ofi_contribution(q("10.00", "10.02", 100, 50), q("10.00", "10.01", 100, 40)),
               -40
             )

      assert Decimal.equal?(
               M.ofi_contribution(q("10.00", "10.02", 100, 50), q("10.00", "10.02", 100, 20)),
               30
             )

      assert Decimal.equal?(
               M.ofi_contribution(q("10.00", "10.02", 100, 50), q("10.00", "10.03", 100, 90)),
               50
             )
    end

    test "a nil size counts as 0 by default, or makes the update unknown with nil_size: :skip" do
      prev = q("10.00", "10.02", nil, 50)
      curr = q("10.00", "10.02", 40, 50)
      assert Decimal.equal?(M.ofi_contribution(prev, curr), 40)
      assert M.ofi_contribution(prev, curr, nil_size: :skip) == nil
    end

    test "a zero side is a price by default, or an empty side with empty_side: :skip" do
      prev = q("0", "10.02", 0, 50)
      curr = q("10.00", "10.02", 100, 50)
      assert Decimal.equal?(M.ofi_contribution(prev, curr), 100)
      assert M.ofi_contribution(prev, curr, empty_side: :skip) == nil
    end

    test "a missing price is nil, never a raise" do
      assert M.ofi_contribution(%{bid: nil, ask: d("10")}, q("10", "10.02", 1, 1)) == nil
      assert M.ofi_contribution(%{}, q("10", "10.02", 1, 1)) == nil
    end
  end

  describe "trade_sign/5 (Lee-Ready)" do
    @quote %{
      bid: Decimal.new("10.00"),
      ask: Decimal.new("10.02"),
      bid_size: Decimal.new(100),
      ask_size: Decimal.new(100)
    }

    test "above the mid buys, below sells" do
      assert M.trade_sign(d("10.02"), @quote, nil, nil) == 1
      assert M.trade_sign(d("10.00"), @quote, nil, nil) == -1
    end

    test "at the mid, the tick rule decides (and a zero tick inherits)" do
      assert M.trade_sign(d("10.01"), @quote, d("10.00"), nil) == 1
      assert M.trade_sign(d("10.01"), @quote, d("10.02"), nil) == -1
      assert M.trade_sign(d("10.01"), @quote, d("10.01"), -1) == -1
    end

    test "no usable quote falls back to the tick rule" do
      for quote <- [
            nil,
            %{bid: nil, ask: d("10.02")},
            q("10.02", "10.02", 1, 1),
            q("10.03", "10.02", 1, 1)
          ] do
        assert M.trade_sign(d("10.05"), quote, d("10.00"), nil) == 1, inspect(quote)
      end
    end

    test "a zero side counts as a quote by default, not with empty_side: :skip" do
      quote = q("0", "10.02", 0, 100)
      # mid 5.01: 10.00 is above it
      assert M.trade_sign(d("10.00"), quote, d("10.05"), nil) == 1
      # empty side -> tick rule: down from 10.05
      assert M.trade_sign(d("10.00"), quote, d("10.05"), nil, empty_side: :skip) == -1
    end

    test "nothing to sign against is nil" do
      assert M.trade_sign(d("10.01"), nil, nil, nil) == nil
      assert M.tick_sign(d("10.01"), nil, 1) == nil
    end
  end

  property "Compute's :ofi total equals the sum of per-event contributions" do
    check all(
            moves <-
              list_of({integer(-2..2), integer(-2..2), integer(1..500), integer(1..500)},
                min_length: 2,
                max_length: 60
              )
          ) do
      {quotes, _} =
        Enum.map_reduce(moves, {1000, 1002}, fn {db, da, bs, as}, {b, a} ->
          b = b + db
          a = max(a + da, b + 1)
          {%{bid: d(b), ask: d(a), bid_size: d(bs), ask_size: d(as)}, {b, a}}
        end)

      t0 = ~U[2026-10-13 14:00:00Z]

      ticks =
        quotes
        |> Enum.with_index()
        |> Enum.map(fn {qt, i} -> Map.put(qt, :at, DateTime.add(t0, i)) end)

      spec = %Spec{kind: :ofi, symbol: "SPY", window_ms: :timer.hours(1), params: %{}}
      {:ok, st} = Compute.init(spec)

      {_st, last} =
        Enum.reduce(ticks, {st, nil}, fn tick, {st, _} -> Compute.step(spec, st, tick) end)

      expected =
        quotes
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [prev, curr] -> M.ofi_contribution(prev, curr) end)
        |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

      assert Decimal.equal?(last, expected)
    end
  end
end
