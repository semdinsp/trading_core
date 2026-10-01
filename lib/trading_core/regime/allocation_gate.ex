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
  - `{:reject, reason, details}` — less than one lot fits. In order of
    precedence `reason` is `:invalid_input` (see below), `:unknown_bucket`
    (bucket not in the budget), `:missing_risk_input` (`risk_per_unit`
    nil, unparseable or not positive), `:below_one_lot` (the sized
    quantity itself is under one lot, e.g. a `size_multiplier` of 0), or
    the first cap in order whose limit is under one lot.

  `details` is `%{binding, headroom, requested_qty, final_qty}`. `headroom`
  holds the remaining dollars per cap (and remaining slots for
  `:bucket_positions`), floored at zero; `nil` means that cap is not set.
  `final_qty` is `0` on a reject.

  ## Never raises; fails closed

  `decide/3` runs inside trading_live's guardian `handle_call`, so it
  never raises. Any input it cannot trust rejects with `:invalid_input`
  rather than being guessed at:

  - entry: `qty` must be `>= 0`; `price`, `multiplier` and `lot_size` must
    be `> 0` (a zero price would otherwise switch off both notional caps).
    `multiplier`, `lot_size` and `size_multiplier` default to 1 when nil.
  - book: every `open_risk`/`gross_notional` present must be a number
    `>= 0` and every `count` a non-negative integer. A missing bucket or
    key counts as zero usage. Portfolio usage is taken as at least the
    bucket's, so a book without a `:portfolio` entry can't fail open.
  - budget: `equity > 0`, every percentage `>= 0`, `max_positions` a
    non-negative integer, and each bucket config may use only the keys
    `:max_open_risk_pct`, `:max_gross_notional_pct` and `:max_positions`
    (a misspelled key would otherwise silently unset that cap).

  `size_multiplier` is clamped to `[0, 1]`: the gate never upsizes, even
  if a caller skips `TradingCore.Regime.Playbook.validate_rule/1`.

  ## Units

  Percentages in the budget are percent of `equity` (`0.30` means 0.30%,
  `100` means 1× equity). All dollar caps and headroom are rounded down to
  cents, so the check is never looser than the configured cap. A bucket
  cap left `nil` is treated as not set.
  """

  alias TradingCore.Regime.Decimals
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
          | :invalid_input

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
              optional(:max_open_risk_pct) => Signals.sample() | nil,
              optional(:max_gross_notional_pct) => Signals.sample() | nil,
              optional(:max_positions) => non_neg_integer() | nil
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
  @bucket_keys [:max_open_risk_pct, :max_gross_notional_pct, :max_positions]

  @doc """
  Turns a budget's percentages into dollar caps:
  `%{per_trade, max_open_risk, max_gross_notional, buckets: %{bucket =>
  %{max_open_risk, max_gross_notional, max_positions}}}`. Rounded down to
  cents; an unset bucket cap stays `nil`.

  Raises `ArgumentError` on a budget `decide/3` would reject as
  `:invalid_input` — this one is for display and config validation, not
  the hot path.
  """
  @spec budget_dollars(budget()) :: map()
  def budget_dollars(budget) do
    case dollar_caps(budget) do
      {:ok, caps} -> caps
      :error -> raise ArgumentError, "invalid allocation budget: #{inspect(budget)}"
    end
  end

  @doc "Decides one entry. See the moduledoc."
  @spec decide(entry(), book(), budget()) ::
          {:allow, Decimal.t(), details()}
          | {:resize, Decimal.t(), reason(), details()}
          | {:reject, reason(), details()}
  def decide(entry, book, budget) do
    requested = requested_qty(entry)

    with {:caps, {:ok, caps}} <- {:caps, dollar_caps(budget)},
         {:entry, {:ok, e}} <- {:entry, normalize_entry(entry)},
         {:book, {:ok, bucket_book, portfolio_book}} <- {:book, normalize_book(book, e.bucket)},
         {:bucket, {:ok, bucket_caps}} <- {:bucket, Map.fetch(caps.buckets, e.bucket)},
         {:rpu, {:ok, rpu}} <- {:rpu, Decimals.parse(Map.get(entry, :risk_per_unit), :pos, [])} do
      decide_within(e, rpu, caps, bucket_caps, bucket_book, portfolio_book)
    else
      {:bucket, :error} -> reject(:unknown_bucket, %{}, requested)
      {:rpu, :error} -> reject(:missing_risk_input, %{}, requested)
      _ -> reject(:invalid_input, %{}, requested)
    end
  end

  ## ---------------------------------------------------------------------
  ## Decision
  ## ---------------------------------------------------------------------

  defp decide_within(e, rpu, caps, bucket_caps, bucket_book, portfolio_book) do
    notional_per_unit = Decimal.mult(e.price, e.multiplier)

    headroom = %{
      per_trade_risk: caps.per_trade,
      bucket_positions: slots_left(bucket_caps.max_positions, bucket_book.count),
      bucket_risk: dollars_left(bucket_caps.max_open_risk, bucket_book.open_risk),
      bucket_notional: dollars_left(bucket_caps.max_gross_notional, bucket_book.gross_notional),
      portfolio_risk: dollars_left(caps.max_open_risk, portfolio_book.open_risk),
      portfolio_notional: dollars_left(caps.max_gross_notional, portfolio_book.gross_notional)
    }

    limits = [
      per_trade_risk_cap: fit(headroom.per_trade_risk, rpu, e.lot),
      bucket_position_cap: slot_limit(headroom.bucket_positions),
      bucket_risk_cap: fit(headroom.bucket_risk, rpu, e.lot),
      bucket_notional_cap: fit(headroom.bucket_notional, notional_per_unit, e.lot),
      portfolio_risk_cap: fit(headroom.portfolio_risk, rpu, e.lot),
      portfolio_notional_cap: fit(headroom.portfolio_notional, notional_per_unit, e.lot)
    ]

    sized = floor_lots(Decimal.mult(e.qty, e.size_multiplier), e.lot)
    final = Enum.reduce(limits, sized, fn {_, limit}, acc -> min_qty(acc, limit) end)

    cond do
      Decimal.compare(sized, e.lot) == :lt ->
        reject(:below_one_lot, headroom, e.qty)

      Decimal.compare(final, e.lot) == :lt ->
        reason = first_reason(limits, &below?(&1, e.lot))
        reject(reason, headroom, e.qty)

      Decimal.compare(final, sized) == :lt ->
        reason = first_reason(limits, &(&1 != :infinity and Decimal.equal?(&1, final)))
        {:resize, final, reason, details(reason, headroom, e.qty, final)}

      true ->
        {:allow, final, details(nil, headroom, e.qty, final)}
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
  defp slot_limit(slots) when is_integer(slots) and slots > 0, do: :infinity

  defp slots_left(nil, _count), do: nil
  defp slots_left(max, count), do: max(max - count, 0)

  defp dollars_left(nil, _used), do: nil

  defp dollars_left(cap, used) do
    cap
    |> Decimal.sub(used)
    |> Decimal.max(Decimal.new(0))
    |> Decimal.round(@dollar_precision, :floor)
  end

  # Largest whole number of lots whose cost (qty × unit) fits in headroom.
  # unit is always > 0 here (validated price/multiplier, rpu).
  defp fit(nil, _unit, _lot), do: :infinity

  defp fit(headroom, unit, lot) do
    headroom |> Decimal.div(unit) |> floor_lots(lot) |> shrink_to_fit(headroom, unit, lot)
  end

  # Decimal.div rounds at 28 significant digits; step down if that pushed
  # a quotient just past a lot boundary. If the quotient is so large that
  # subtracting a lot no longer changes it, give up and allow nothing
  # rather than loop.
  defp shrink_to_fit(qty, headroom, unit, lot) do
    if Decimal.compare(qty, 0) == :gt and
         Decimal.compare(Decimal.mult(qty, unit), headroom) == :gt do
      smaller = Decimal.sub(qty, lot)

      if Decimal.equal?(smaller, qty),
        do: Decimal.new(0),
        else: shrink_to_fit(smaller, headroom, unit, lot)
    else
      qty
    end
  end

  defp floor_lots(qty, lot) do
    qty
    |> Decimal.div(lot)
    |> Decimal.round(0, :floor)
    |> Decimal.max(Decimal.new(0))
    |> Decimal.mult(lot)
  end

  ## ---------------------------------------------------------------------
  ## Input validation (never raises)
  ## ---------------------------------------------------------------------

  defp dollar_caps(%{} = budget) do
    with {:ok, equity} <- Decimals.parse(Map.get(budget, :equity), :pos, []),
         {:ok, per_trade} <- required_pct(equity, Map.get(budget, :risk_per_trade_pct)),
         {:ok, max_risk} <- required_pct(equity, Map.get(budget, :max_open_risk_pct)),
         {:ok, max_notional} <- required_pct(equity, Map.get(budget, :max_gross_notional_pct)),
         {:ok, buckets} <- bucket_caps(equity, Map.get(budget, :buckets, %{})) do
      {:ok,
       %{
         per_trade: per_trade,
         max_open_risk: max_risk,
         max_gross_notional: max_notional,
         buckets: buckets
       }}
    end
  end

  defp dollar_caps(_budget), do: :error

  defp bucket_caps(equity, buckets) when is_map(buckets) do
    Enum.reduce_while(buckets, {:ok, %{}}, fn {bucket, config}, {:ok, acc} ->
      case bucket_cap(equity, config) do
        {:ok, caps} -> {:cont, {:ok, Map.put(acc, bucket, caps)}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp bucket_caps(_equity, _buckets), do: :error

  defp bucket_cap(equity, %{} = config) do
    with [] <- Map.keys(config) -- @bucket_keys,
         {:ok, risk} <- optional_pct(equity, Map.get(config, :max_open_risk_pct)),
         {:ok, notional} <- optional_pct(equity, Map.get(config, :max_gross_notional_pct)),
         {:ok, positions} <- max_positions(Map.get(config, :max_positions)) do
      {:ok, %{max_open_risk: risk, max_gross_notional: notional, max_positions: positions}}
    else
      _ -> :error
    end
  end

  defp bucket_cap(_equity, _config), do: :error

  defp max_positions(nil), do: {:ok, nil}
  defp max_positions(n) when is_integer(n) and n >= 0, do: {:ok, n}

  defp max_positions(%Decimal{} = d) do
    if Decimals.parse(d, :non_neg, []) != :error and Decimal.integer?(d),
      do: {:ok, Decimal.to_integer(d)},
      else: :error
  end

  defp max_positions(_), do: :error

  defp required_pct(_equity, nil), do: :error
  defp required_pct(equity, pct), do: optional_pct(equity, pct)

  defp optional_pct(_equity, nil), do: {:ok, nil}

  defp optional_pct(equity, pct) do
    with {:ok, pct} <- Decimals.parse(pct, :non_neg, []) do
      {:ok,
       equity |> Decimal.mult(pct) |> Decimal.div(100) |> Decimal.round(@dollar_precision, :floor)}
    end
  end

  defp normalize_entry(%{} = entry) do
    with {:ok, qty} <- Decimals.parse(Map.get(entry, :qty), :non_neg, []),
         {:ok, price} <- Decimals.parse(Map.get(entry, :price), :pos, []),
         {:ok, multiplier} <- Decimals.parse(Map.get(entry, :multiplier) || 1, :pos, []),
         {:ok, lot} <- Decimals.parse(Map.get(entry, :lot_size) || 1, :pos, []),
         {:ok, size_multiplier} <-
           Decimals.parse(Map.get(entry, :size_multiplier) || 1, :non_neg, []) do
      {:ok,
       %{
         bucket: Map.get(entry, :bucket),
         qty: qty,
         price: price,
         multiplier: multiplier,
         lot: lot,
         size_multiplier: Decimal.min(size_multiplier, Decimal.new(1))
       }}
    end
  end

  defp normalize_entry(_entry), do: :error

  defp normalize_book(%{} = book, bucket) do
    with {:ok, b} <- usage(Map.get(book, bucket, %{})),
         {:ok, p} <- usage(Map.get(book, :portfolio, %{})) do
      portfolio = %{
        open_risk: Decimal.max(p.open_risk, b.open_risk),
        gross_notional: Decimal.max(p.gross_notional, b.gross_notional),
        count: max(p.count, b.count)
      }

      {:ok, b, portfolio}
    end
  end

  defp normalize_book(_book, _bucket), do: :error

  defp usage(%{} = totals) do
    with {:ok, risk} <- Decimals.parse(Map.get(totals, :open_risk, 0), :non_neg, []),
         {:ok, notional} <- Decimals.parse(Map.get(totals, :gross_notional, 0), :non_neg, []),
         count when is_integer(count) and count >= 0 <- Map.get(totals, :count, 0) do
      {:ok, %{open_risk: risk, gross_notional: notional, count: count}}
    else
      _ -> :error
    end
  end

  defp usage(_totals), do: :error

  defp requested_qty(%{} = entry) do
    case Decimals.parse(Map.get(entry, :qty)) do
      {:ok, qty} -> qty
      :error -> Decimal.new(0)
    end
  end

  defp requested_qty(_entry), do: Decimal.new(0)
end
