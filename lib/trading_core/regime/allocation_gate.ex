defmodule TradingCore.Regime.AllocationGate do
  @moduledoc """
  Budget check for one new entry against one book: may it open, at what
  quantity, and if not, which cap stopped it.

  Pure. The caller (trading_live's guardian) owns the book, reservations
  and the budget config, computes `risk_per_unit` (see
  `TradingCore.Regime.Exposure.risk_per_unit/1`) and the playbook's
  `size_multiplier` (see `TradingCore.Regime.Playbook`), and passes them in.

  ## Order of application

  1. `size_multiplier` scales the requested quantity (rounded down to a lot).
  2. Caps, in this order — the order decides which reason is reported:
     per-trade risk → bucket position count → bucket open risk → bucket
     gross notional → portfolio open risk → portfolio gross notional.

  The final quantity is the smallest of the sized quantity and every
  cap's limit, **rounded down** to `lot_size`. (`TradingCore.PositionSizing`
  rounds up; this must not, or the result could exceed a cap.)

  ## Results

  - `{:allow, qty, details}` — no cap bound. A reduction caused only by
    `size_multiplier` < 1 is still `:allow`.
  - `{:resize, qty, reason, details}` — a cap reduced the quantity;
    `reason` is the first cap (in the order above) whose limit equals the
    final quantity.
  - `{:reject, reason, details}` — less than one lot fits. `reason` is
    `:unknown_bucket` (bucket not in the budget), `:missing_risk_input`
    (`risk_per_unit` nil or not positive), `:below_one_lot` (the sized
    quantity itself is under one lot, e.g. a `size_multiplier` of 0), or
    the first cap in order whose limit is under one lot.

  `details` is `%{binding, headroom, requested_qty, final_qty}`. `headroom`
  holds the remaining dollars per cap (and remaining slots for
  `:bucket_positions`), floored at zero; `nil` means that cap is not set.
  `final_qty` is `0` on a reject.

  ## Units

  Percentages in the budget are percent of `equity` (`0.30` means 0.30%,
  `100` means 1× equity). All dollar caps and headroom are rounded down to
  cents, so the check is never looser than the configured cap. A bucket
  cap left `nil` is treated as not set.
  """

  alias TradingCore.Signals

  @type reason ::
          :per_trade_risk_cap
          | :bucket_position_cap
          | :bucket_risk_cap
          | :bucket_notional_cap
          | :portfolio_risk_cap
          | :portfolio_notional_cap
          | :unknown_bucket
          | :missing_risk_input
          | :below_one_lot

  @type entry :: %{
          required(:bucket) => String.t(),
          required(:qty) => Signals.sample(),
          required(:price) => Signals.sample(),
          required(:risk_per_unit) => Signals.sample() | nil,
          optional(:multiplier) => Signals.sample(),
          optional(:size_multiplier) => Signals.sample(),
          optional(:lot_size) => Signals.sample()
        }

  @type totals :: %{
          open_risk: Signals.sample(),
          gross_notional: Signals.sample(),
          count: non_neg_integer()
        }
  @type book :: %{optional(String.t() | :portfolio) => totals()}

  @type budget :: %{
          equity: Signals.sample(),
          risk_per_trade_pct: Signals.sample(),
          max_open_risk_pct: Signals.sample(),
          max_gross_notional_pct: Signals.sample(),
          buckets: %{
            String.t() => %{
              max_open_risk_pct: Signals.sample() | nil,
              max_gross_notional_pct: Signals.sample() | nil,
              max_positions: non_neg_integer() | nil
            }
          }
        }

  @type details :: %{
          binding: reason() | nil,
          headroom: map(),
          requested_qty: Decimal.t(),
          final_qty: Decimal.t()
        }

  @dollar_precision 2

  @doc """
  Turns a budget's percentages into dollar caps:
  `%{per_trade, max_open_risk, max_gross_notional, buckets: %{bucket =>
  %{max_open_risk, max_gross_notional, max_positions}}}`. Rounded down to
  cents; an unset bucket cap stays `nil`.
  """
  @spec budget_dollars(budget()) :: map()
  def budget_dollars(budget) do
    equity = to_decimal(budget.equity)

    %{
      per_trade: pct_of(equity, budget.risk_per_trade_pct),
      max_open_risk: pct_of(equity, budget.max_open_risk_pct),
      max_gross_notional: pct_of(equity, budget.max_gross_notional_pct),
      buckets:
        Map.new(Map.get(budget, :buckets, %{}), fn {bucket, caps} ->
          {bucket,
           %{
             max_open_risk: pct_of(equity, Map.get(caps, :max_open_risk_pct)),
             max_gross_notional: pct_of(equity, Map.get(caps, :max_gross_notional_pct)),
             max_positions: Map.get(caps, :max_positions)
           }}
        end)
    }
  end

  @doc "Decides one entry. See the moduledoc."
  @spec decide(entry(), book(), budget()) ::
          {:allow, Decimal.t(), details()}
          | {:resize, Decimal.t(), reason(), details()}
          | {:reject, reason(), details()}
  def decide(entry, book, budget) do
    caps = budget_dollars(budget)
    requested = to_decimal(entry.qty)
    rpu = optional_decimal(Map.get(entry, :risk_per_unit))

    cond do
      not Map.has_key?(caps.buckets, entry.bucket) ->
        reject(:unknown_bucket, %{}, requested)

      rpu == nil or Decimal.compare(rpu, 0) != :gt ->
        reject(:missing_risk_input, %{}, requested)

      true ->
        decide_within(entry, book, caps, requested, rpu)
    end
  end

  ## ---------------------------------------------------------------------

  defp decide_within(entry, book, caps, requested, rpu) do
    lot = to_decimal(Map.get(entry, :lot_size) || 1)
    size_multiplier = to_decimal(Map.get(entry, :size_multiplier) || 1)

    notional_per_unit =
      Decimal.mult(to_decimal(entry.price), to_decimal(Map.get(entry, :multiplier) || 1))

    bucket_caps = Map.fetch!(caps.buckets, entry.bucket)
    bucket_book = Map.get(book, entry.bucket, %{})
    portfolio_book = Map.get(book, :portfolio, %{})

    headroom = %{
      per_trade_risk: caps.per_trade,
      bucket_positions: slots_left(bucket_caps.max_positions, Map.get(bucket_book, :count, 0)),
      bucket_risk: dollars_left(bucket_caps.max_open_risk, Map.get(bucket_book, :open_risk)),
      bucket_notional:
        dollars_left(bucket_caps.max_gross_notional, Map.get(bucket_book, :gross_notional)),
      portfolio_risk: dollars_left(caps.max_open_risk, Map.get(portfolio_book, :open_risk)),
      portfolio_notional:
        dollars_left(caps.max_gross_notional, Map.get(portfolio_book, :gross_notional))
    }

    limits = [
      per_trade_risk_cap: fit(headroom.per_trade_risk, rpu, lot),
      bucket_position_cap: slot_limit(headroom.bucket_positions),
      bucket_risk_cap: fit(headroom.bucket_risk, rpu, lot),
      bucket_notional_cap: fit(headroom.bucket_notional, notional_per_unit, lot),
      portfolio_risk_cap: fit(headroom.portfolio_risk, rpu, lot),
      portfolio_notional_cap: fit(headroom.portfolio_notional, notional_per_unit, lot)
    ]

    sized = floor_lots(Decimal.mult(requested, size_multiplier), lot)
    final = Enum.reduce(limits, sized, fn {_, limit}, acc -> min_qty(acc, limit) end)

    cond do
      Decimal.compare(sized, lot) == :lt ->
        reject(:below_one_lot, headroom, requested)

      Decimal.compare(final, lot) == :lt ->
        reason = first_reason(limits, &below?(&1, lot))
        reject(reason, headroom, requested)

      Decimal.compare(final, sized) == :lt ->
        reason = first_reason(limits, &(&1 != :infinity and Decimal.equal?(&1, final)))
        {:resize, final, reason, details(reason, headroom, requested, final)}

      true ->
        {:allow, final, details(nil, headroom, requested, final)}
    end
  end

  defp reject(reason, headroom, requested) do
    {:reject, reason, details(reason, headroom, requested, Decimal.new(0))}
  end

  defp details(binding, headroom, requested, final) do
    %{binding: binding, headroom: headroom, requested_qty: requested, final_qty: final}
  end

  defp first_reason(limits, pred) do
    Enum.find_value(limits, fn {reason, limit} -> if pred.(limit), do: reason end)
  end

  defp below?(:infinity, _lot), do: false
  defp below?(limit, lot), do: Decimal.compare(limit, lot) == :lt

  defp min_qty(qty, :infinity), do: qty
  defp min_qty(qty, limit), do: Decimal.min(qty, limit)

  defp slot_limit(nil), do: :infinity
  defp slot_limit(0), do: Decimal.new(0)
  defp slot_limit(_slots), do: :infinity

  defp slots_left(nil, _count), do: nil
  defp slots_left(max, count), do: max(max - count, 0)

  defp dollars_left(nil, _used), do: nil

  defp dollars_left(cap, used) do
    left = Decimal.sub(cap, to_decimal(used || 0))
    left |> Decimal.max(Decimal.new(0)) |> Decimal.round(@dollar_precision, :floor)
  end

  # Largest whole number of lots whose cost (qty × unit) fits in headroom.
  defp fit(nil, _unit, _lot), do: :infinity

  defp fit(headroom, unit, lot) do
    if Decimal.compare(unit, 0) != :gt do
      :infinity
    else
      headroom |> Decimal.div(unit) |> floor_lots(lot) |> shrink_to_fit(headroom, unit, lot)
    end
  end

  # Decimal.div rounds at 28 significant digits; step down if that pushed
  # a quotient just past a lot boundary.
  defp shrink_to_fit(qty, headroom, unit, lot) do
    if Decimal.compare(qty, 0) == :gt and
         Decimal.compare(Decimal.mult(qty, unit), headroom) == :gt,
       do: shrink_to_fit(Decimal.sub(qty, lot), headroom, unit, lot),
       else: qty
  end

  defp floor_lots(qty, lot) do
    qty
    |> Decimal.div(lot)
    |> Decimal.round(0, :floor)
    |> Decimal.max(Decimal.new(0))
    |> Decimal.mult(lot)
  end

  defp pct_of(_equity, nil), do: nil

  defp pct_of(equity, pct) do
    equity
    |> Decimal.mult(to_decimal(pct))
    |> Decimal.div(100)
    |> Decimal.round(@dollar_precision, :floor)
  end

  defp optional_decimal(nil), do: nil
  defp optional_decimal(value), do: to_decimal(value)

  defp to_decimal(%Decimal{} = value), do: value
  defp to_decimal(value) when is_float(value), do: Decimal.from_float(value)
  defp to_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp to_decimal(value) when is_binary(value), do: Decimal.new(value)
end
