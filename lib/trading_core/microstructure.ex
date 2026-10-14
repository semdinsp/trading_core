defmodule TradingCore.Microstructure do
  @moduledoc """
  Per-event order-flow arithmetic: the Cont–Kukanov–Stoikov order-flow
  imbalance of one quote update (`ofi_contribution/3`) and the Lee–Ready /
  tick-rule sign of one trade (`trade_sign/5`, `tick_sign/3`).

  `TradingCore.Signal.Compute`'s `:ofi` and `:signed_volume` kinds sum
  these over a rolling window; trading_micro sums them per second and
  trading_backtest's quote ingest needs the same per-event rules. One
  implementation here keeps them from drifting (a copied formula is how
  the pre-2026-09-25 inverted-ask OFI bug happened).

  Pure, `Decimal` throughout. A quote is `%{bid:, ask:, bid_size:,
  ask_size:}`.

  ## Missing sizes and empty sides

  The defaults are `Compute`'s behaviour, so its signals are unchanged:

    * `nil_size: :zero` (default) treats a missing size as 0;
      `nil_size: :skip` makes the update unknown (`nil`) instead, for a
      caller whose feed contract is "nil is not zero".
    * `empty_side: :price` (default) uses a zero bid or ask as a price;
      `empty_side: :skip` treats it as an empty side (Polygon's), giving no
      OFI and no usable mid.

  A missing bid or ask price always makes the OFI update `nil`.
  """

  @type quote_state :: %{
          optional(:bid) => Decimal.t() | nil,
          optional(:ask) => Decimal.t() | nil,
          optional(:bid_size) => Decimal.t() | nil,
          optional(:ask_size) => Decimal.t() | nil
        }

  @doc """
  The order-flow imbalance contributed by moving from quote `prev` to
  quote `curr`. Positive is buy pressure:

    * bid side: a higher bid adds its new size; an unchanged bid adds the
      change in size; a lower bid removes the previous size.
    * ask side: a lower ask removes (sells) its new size; an unchanged ask
      adds the decrease in size; a higher ask adds the previous size.

  `nil` when a price is missing, or under the `:skip` options above.
  """
  @spec ofi_contribution(quote_state(), quote_state(), keyword()) :: Decimal.t() | nil
  def ofi_contribution(prev, curr, opts \\ []) do
    with {:ok, prev} <- usable_quote(prev, opts),
         {:ok, curr} <- usable_quote(curr, opts) do
      Decimal.add(
        bid_contribution(prev.bid, prev.bid_size, curr.bid, curr.bid_size),
        ask_contribution(prev.ask, prev.ask_size, curr.ask, curr.ask_size)
      )
    else
      :skip -> nil
    end
  end

  @doc """
  The Lee–Ready sign of a trade at `price`: `1` (buy) above the quote's
  mid, `-1` (sell) below it. At the mid, or with no usable quote (`nil`,
  a missing side, or ask not above bid; a zero side too under
  `empty_side: :skip`), it falls back to `tick_sign/3`. `nil` when there
  is nothing to sign against.
  """
  @spec trade_sign(Decimal.t(), quote_state() | nil, Decimal.t() | nil, 1 | -1 | nil, keyword()) ::
          1 | -1 | nil
  def trade_sign(price, quote, last_price, last_sign, opts \\ []) do
    case mid(quote, opts) do
      nil ->
        tick_sign(price, last_price, last_sign)

      mid ->
        case Decimal.compare(price, mid) do
          :gt -> 1
          :lt -> -1
          :eq -> tick_sign(price, last_price, last_sign)
        end
    end
  end

  @doc """
  Tick rule: up from `last_price` is a buy (`1`), down a sell (`-1`), and
  an unchanged price inherits `last_sign` (a repeat print is attributed
  to whichever side pressed last, rather than counted as neutral). `nil`
  with no previous price.
  """
  @spec tick_sign(Decimal.t(), Decimal.t() | nil, 1 | -1 | nil) :: 1 | -1 | nil
  def tick_sign(_price, nil, _last_sign), do: nil

  def tick_sign(price, last_price, last_sign) do
    case Decimal.compare(price, last_price) do
      :gt -> 1
      :lt -> -1
      :eq -> last_sign
    end
  end

  ## ---------------------------------------------------------------------

  defp usable_quote(%{bid: %Decimal{} = bid, ask: %Decimal{} = ask} = q, opts) do
    cond do
      Keyword.get(opts, :empty_side, :price) == :skip and
          (Decimal.compare(bid, 0) != :gt or Decimal.compare(ask, 0) != :gt) ->
        :skip

      Keyword.get(opts, :nil_size, :zero) == :skip and
          (is_nil(Map.get(q, :bid_size)) or is_nil(Map.get(q, :ask_size))) ->
        :skip

      true ->
        {:ok,
         %{bid: bid, ask: ask, bid_size: Map.get(q, :bid_size), ask_size: Map.get(q, :ask_size)}}
    end
  end

  defp usable_quote(_quote, _opts), do: :skip

  defp bid_contribution(prev_price, prev_size, curr_price, curr_size) do
    prev_size = prev_size || Decimal.new(0)
    curr_size = curr_size || Decimal.new(0)

    case Decimal.compare(curr_price, prev_price) do
      # Bid rose: the size at the new, better level is new buying interest.
      :gt -> curr_size
      # Unchanged: only the change in resting size is new.
      :eq -> Decimal.sub(curr_size, prev_size)
      # Bid fell: the whole previous level was pulled or hit.
      :lt -> Decimal.negate(prev_size)
    end
  end

  defp ask_contribution(prev_price, prev_size, curr_price, curr_size) do
    prev_size = prev_size || Decimal.new(0)
    curr_size = curr_size || Decimal.new(0)

    case Decimal.compare(curr_price, prev_price) do
      # Ask fell: the size at the new, better offer is new selling interest.
      :lt -> Decimal.negate(curr_size)
      # Unchanged: added offer size is sell pressure, removed is buy.
      :eq -> Decimal.sub(prev_size, curr_size)
      # Ask rose: the whole previous offer was lifted or pulled.
      :gt -> prev_size
    end
  end

  # The quote's mid when it can sign a trade: both sides present and ask
  # above bid (and, under empty_side: :skip, both sides positive).
  defp mid(%{bid: %Decimal{} = bid, ask: %Decimal{} = ask}, opts) do
    empty? =
      Keyword.get(opts, :empty_side, :price) == :skip and
        (Decimal.compare(bid, 0) != :gt or Decimal.compare(ask, 0) != :gt)

    if not empty? and Decimal.compare(ask, bid) == :gt,
      do: bid |> Decimal.add(ask) |> Decimal.div(2),
      else: nil
  end

  defp mid(_quote, _opts), do: nil
end
