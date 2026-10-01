defmodule TradingCore.Regime.AllocationGateTest.Helpers do
  @moduledoc false

  def d(s), do: Decimal.new(s)

  def book(bucket, portfolio), do: %{"tick" => bucket, portfolio: portfolio}

  def totals(risk, notional, count) do
    %{open_risk: d(risk), gross_notional: d(notional), count: count}
  end
end

defmodule TradingCore.Regime.AllocationGateTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias TradingCore.Regime.AllocationGate

  import TradingCore.Regime.AllocationGateTest.Helpers

  # $50k book, 0.30% per trade ($150), 2% open risk ($1000), 100% gross
  # ($50k); "tick" bucket: 1% risk ($500), 40% notional ($20k), 3 positions.
  @budget %{
    equity: Decimal.new(50_000),
    risk_per_trade_pct: Decimal.new("0.30"),
    max_open_risk_pct: Decimal.new(2),
    max_gross_notional_pct: Decimal.new(100),
    buckets: %{
      "tick" => %{
        max_open_risk_pct: Decimal.new(1),
        max_gross_notional_pct: Decimal.new(40),
        max_positions: 3
      }
    }
  }

  @empty_book %{}

  defp entry(attrs \\ []) do
    Map.merge(
      %{
        bucket: "tick",
        qty: d("10"),
        price: d("100"),
        multiplier: d("1"),
        risk_per_unit: d("5"),
        size_multiplier: d("1"),
        lot_size: d("1")
      },
      Map.new(attrs)
    )
  end

  describe "budget_dollars/1" do
    test "turns percentages of equity into rounded dollar caps" do
      caps = AllocationGate.budget_dollars(@budget)

      assert Decimal.equal?(caps.per_trade, d("150"))
      assert Decimal.equal?(caps.max_open_risk, d("1000"))
      assert Decimal.equal?(caps.max_gross_notional, d("50000"))
      assert Decimal.equal?(caps.buckets["tick"].max_open_risk, d("500"))
      assert Decimal.equal?(caps.buckets["tick"].max_gross_notional, d("20000"))
      assert caps.buckets["tick"].max_positions == 3
    end
  end

  describe "decide/3" do
    test "allows when nothing binds" do
      assert {:allow, qty, %{binding: nil, requested_qty: req, final_qty: qty}} =
               AllocationGate.decide(entry(), @empty_book, @budget)

      assert Decimal.equal?(qty, 10)
      assert Decimal.equal?(req, 10)
    end

    test "a size_multiplier reduction alone is :allow, rounded down to a lot" do
      assert {:allow, qty, _} =
               AllocationGate.decide(entry(size_multiplier: d("0.55")), @empty_book, @budget)

      assert Decimal.equal?(qty, 5)
    end

    # Each case: entry overrides, book, expected reason, expected qty.
    resize_cases = [
      {"per-trade risk", [qty: d("100")], %{}, :per_trade_risk_cap, "30"},
      {"bucket open risk", [], book(totals("480", "0", 0), totals("480", "0", 0)),
       :bucket_risk_cap, "4"},
      {"bucket notional", [], book(totals("0", "19500", 0), totals("0", "19500", 0)),
       :bucket_notional_cap, "5"},
      {"portfolio open risk", [], book(totals("0", "0", 0), totals("985", "0", 0)),
       :portfolio_risk_cap, "3"},
      {"portfolio notional", [], book(totals("0", "0", 0), totals("0", "49700", 0)),
       :portfolio_notional_cap, "3"}
    ]

    for {name, overrides, book, reason, qty} <- resize_cases do
      @overrides overrides
      @book book
      @reason reason
      @qty qty
      test "resizes on #{name}" do
        assert {:resize, qty, @reason, %{binding: @reason}} =
                 AllocationGate.decide(entry(@overrides), @book, @budget)

        assert Decimal.equal?(qty, d(@qty))
      end
    end

    test "rejects at the bucket position cap" do
      assert {:reject, :bucket_position_cap, %{final_qty: zero}} =
               AllocationGate.decide(
                 entry(),
                 book(totals("0", "0", 3), totals("0", "0", 3)),
                 @budget
               )

      assert Decimal.equal?(zero, 0)
    end

    test "below one lot rejects with the first binding reason in order" do
      # bucket risk headroom $2 and portfolio risk headroom $0: both block,
      # bucket risk comes first.
      book = book(totals("498", "0", 0), totals("1000", "0", 0))
      assert {:reject, :bucket_risk_cap, _} = AllocationGate.decide(entry(), book, @budget)
    end

    test "rounds down to lot_size, never up" do
      # per-trade allows 30 shares; lots of 7 ⇒ 28
      assert {:resize, qty, :per_trade_risk_cap, _} =
               AllocationGate.decide(entry(qty: d("100"), lot_size: d("7")), @empty_book, @budget)

      assert Decimal.equal?(qty, 28)
    end

    test "supports fractional lots" do
      assert {:resize, qty, :per_trade_risk_cap, _} =
               AllocationGate.decide(
                 entry(qty: d("100"), risk_per_unit: d("7"), lot_size: d("0.1")),
                 @empty_book,
                 @budget
               )

      # $150 / $7 = 21.43 shares ⇒ 21.4 in lots of 0.1
      assert Decimal.equal?(qty, d("21.4"))
    end

    test "unknown bucket, missing risk, and a zero multiplier reject" do
      assert {:reject, :unknown_bucket, _} =
               AllocationGate.decide(entry(bucket: "nope"), @empty_book, @budget)

      assert {:reject, :missing_risk_input, _} =
               AllocationGate.decide(entry(risk_per_unit: nil), @empty_book, @budget)

      assert {:reject, :missing_risk_input, _} =
               AllocationGate.decide(entry(risk_per_unit: d("0")), @empty_book, @budget)

      assert {:reject, :below_one_lot, _} =
               AllocationGate.decide(entry(size_multiplier: d("0")), @empty_book, @budget)
    end

    test "an unset bucket cap does not bind" do
      budget =
        put_in(@budget, [:buckets, "tick"], %{
          max_open_risk_pct: nil,
          max_gross_notional_pct: nil,
          max_positions: nil
        })

      book = book(totals("10000", "999999", 50), totals("0", "0", 0))

      assert {:allow, _, %{headroom: %{bucket_risk: nil, bucket_positions: nil}}} =
               AllocationGate.decide(entry(), book, budget)
    end

    test "options: notional uses price × multiplier" do
      # 1 contract = $250 notional, $50 risk; bucket notional headroom $600 ⇒ 2
      opt = entry(qty: d("5"), price: d("2.50"), multiplier: d("100"), risk_per_unit: d("50"))
      book = book(totals("0", "19400", 0), totals("0", "19400", 0))

      assert {:resize, qty, :bucket_notional_cap, _} = AllocationGate.decide(opt, book, @budget)
      assert Decimal.equal?(qty, 2)
    end
  end

  ## -----------------------------------------------------------------------
  ## Properties
  ## -----------------------------------------------------------------------

  defp cents(min, max), do: map(integer(min..max), &Decimal.new(1, &1, -2))

  defp scenario do
    gen all(
          equity <- integer(5_000..200_000),
          per_trade <- cents(5, 100),
          port_risk <- cents(50, 500),
          port_notional <- cents(5_000, 20_000),
          bucket_risk <- cents(20, 300),
          bucket_notional <- cents(1_000, 10_000),
          max_positions <- one_of([constant(nil), integer(1..6)]),
          b_risk <- cents(0, 100_000),
          b_notional <- cents(0, 2_000_000),
          b_count <- integer(0..4),
          p_extra_risk <- cents(0, 50_000),
          p_extra_notional <- cents(0, 2_000_000),
          qty <- integer(0..500),
          price <- cents(1, 20_000),
          multiplier <- member_of([1, 100]),
          rpu <- cents(1, 500),
          size_mult <- cents(0, 100),
          lot <- member_of([d("1"), d("10"), d("0.5")])
        ) do
      budget = %{
        equity: Decimal.new(equity),
        risk_per_trade_pct: per_trade,
        max_open_risk_pct: port_risk,
        max_gross_notional_pct: port_notional,
        buckets: %{
          "b" => %{
            max_open_risk_pct: bucket_risk,
            max_gross_notional_pct: bucket_notional,
            max_positions: max_positions
          }
        }
      }

      book = %{
        "b" => %{open_risk: b_risk, gross_notional: b_notional, count: b_count},
        portfolio: %{
          open_risk: Decimal.add(b_risk, p_extra_risk),
          gross_notional: Decimal.add(b_notional, p_extra_notional),
          count: b_count
        }
      }

      entry = %{
        bucket: "b",
        qty: Decimal.new(qty),
        price: price,
        multiplier: Decimal.new(multiplier),
        risk_per_unit: rpu,
        size_multiplier: size_mult,
        lot_size: lot
      }

      {entry, book, budget}
    end
  end

  defp fits?(used, cap, add), do: Decimal.compare(Decimal.add(used, add), cap) != :gt

  defp final_qty({:allow, q, _}), do: q
  defp final_qty({:resize, q, _, _}), do: q
  defp final_qty({:reject, _, _}), do: Decimal.new(0)

  property "an allowed entry never pushes the book past any cap" do
    check all({entry, book, budget} <- scenario(), max_runs: 500) do
      result = AllocationGate.decide(entry, book, budget)

      if elem(result, 0) != :reject do
        qty = final_qty(result)
        caps = AllocationGate.budget_dollars(budget)
        bcaps = caps.buckets["b"]
        risk = Decimal.mult(qty, entry.risk_per_unit)
        notional = qty |> Decimal.mult(entry.price) |> Decimal.mult(entry.multiplier)

        assert fits?(Decimal.new(0), caps.per_trade, risk)
        assert fits?(book["b"].open_risk, bcaps.max_open_risk, risk)
        assert fits?(book["b"].gross_notional, bcaps.max_gross_notional, notional)
        assert fits?(book.portfolio.open_risk, caps.max_open_risk, risk)
        assert fits?(book.portfolio.gross_notional, caps.max_gross_notional, notional)
        assert bcaps.max_positions == nil or book["b"].count + 1 <= bcaps.max_positions
      end
    end
  end

  property "final qty never exceeds the request and is a whole number of lots" do
    check all({entry, book, budget} <- scenario(), max_runs: 500) do
      result = AllocationGate.decide(entry, book, budget)
      qty = final_qty(result)

      assert Decimal.compare(qty, entry.qty) != :gt
      lots = Decimal.div(qty, entry.lot_size)
      assert Decimal.equal?(lots, Decimal.round(lots, 0))
    end
  end

  property "rejects exactly when one lot does not fit" do
    check all({entry, book, budget} <- scenario(), max_runs: 500) do
      caps = AllocationGate.budget_dollars(budget)
      bcaps = caps.buckets["b"]
      lot = entry.lot_size
      risk = Decimal.mult(lot, entry.risk_per_unit)
      notional = lot |> Decimal.mult(entry.price) |> Decimal.mult(entry.multiplier)
      sized_lots = entry.qty |> Decimal.mult(entry.size_multiplier) |> Decimal.div(lot)

      one_lot_fits =
        Decimal.compare(sized_lots, 1) != :lt and
          fits?(Decimal.new(0), caps.per_trade, risk) and
          (bcaps.max_positions == nil or book["b"].count < bcaps.max_positions) and
          fits?(book["b"].open_risk, bcaps.max_open_risk, risk) and
          fits?(book["b"].gross_notional, bcaps.max_gross_notional, notional) and
          fits?(book.portfolio.open_risk, caps.max_open_risk, risk) and
          fits?(book.portfolio.gross_notional, caps.max_gross_notional, notional)

      rejected = elem(AllocationGate.decide(entry, book, budget), 0) == :reject
      assert rejected == not one_lot_fits
    end
  end

  property "more headroom never yields a smaller qty" do
    check all(
            {entry, book, budget} <- scenario(),
            extra_equity <- integer(0..200_000),
            max_runs: 500
          ) do
      bigger = %{budget | equity: Decimal.add(budget.equity, extra_equity)}

      small = final_qty(AllocationGate.decide(entry, book, budget))
      large = final_qty(AllocationGate.decide(entry, book, bigger))

      assert Decimal.compare(large, small) != :lt
    end
  end
end
