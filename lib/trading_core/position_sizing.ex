defmodule TradingCore.PositionSizing do
  @moduledoc """
  Order quantity formulas — extracted from `trading_system`'s
  `TradingSystem.Trading.PositionSizing` into this shared library so
  `trading_system`'s own sizing and `trading_live`'s
  `StrategyStockMonitor` compute the exact same quantity for a given
  config, same as `TradingCore.RiskControls` already does for stop-loss/
  take-profit levels (see that module's own moduledoc) — one place to
  fix if a formula ever changes, not two copies that can silently drift
  apart.

  This module is deliberately pure — no RPC, no I/O. `volatility_target`
  needs a daily volatility figure and a live price, both of which are only
  knowable at the caller's own call site (a real symbol/exchange/price in
  hand at order-placement time, not something this module can pre-compute
  or fetch itself) — `context` carries them in as plain values. Fetching
  `:daily_vol` (an RPC to a volatility service) and `:price` (the current
  quote) is the caller's job; this module only does the arithmetic once
  those are in hand.

  All arithmetic uses `Decimal`, never floats.
  """

  @doc """
  Computes an order quantity from a `position_sizing` config and a
  context map.

  `config["method"]`:
  - `"fixed_qty"` — returns `config["qty"]` as-is (converted to `Decimal`).
    No context required.
  - `"volatility_target"` — `target_dollar_volatility / (daily_vol * price)`.
    Requires `context[:daily_vol]`, `context[:price]`, and
    `context[:target_dollar_volatility]`, all as `Decimal` (or values
    `Decimal.new/1` accepts).

  Returns `{:ok, Decimal.t()}` or `{:error, reason}`. Never fabricates a
  quantity on error — callers must not fall back to a guessed value.
  """
  @spec calculate_qty(map(), map()) :: {:ok, Decimal.t()} | {:error, atom()}
  def calculate_qty(%{"method" => "fixed_qty", "qty" => qty}, _context) do
    with {:ok, qty} <- to_decimal(qty), do: {:ok, qty}
  end

  def calculate_qty(%{"method" => "volatility_target"}, context) do
    with {:ok, daily_vol} <- fetch_context(context, :daily_vol, :daily_vol_required),
         {:ok, price} <- fetch_context(context, :price, :price_required),
         {:ok, target_dollar_volatility} <-
           fetch_context(
             context,
             :target_dollar_volatility,
             :target_dollar_volatility_required
           ),
         {:ok, daily_vol} <- to_decimal(daily_vol),
         {:ok, price} <- to_decimal(price),
         {:ok, target_dollar_volatility} <- to_decimal(target_dollar_volatility),
         false <- Decimal.eq?(daily_vol, 0),
         false <- Decimal.eq?(price, 0) do
      {:ok, Decimal.div(target_dollar_volatility, Decimal.mult(daily_vol, price))}
    else
      true -> {:error, :daily_volatility_unavailable}
      {:error, _reason} = error -> error
    end
  end

  def calculate_qty(_config, _context), do: {:error, :unknown_sizing_method}

  defp fetch_context(context, key, error) do
    case Map.get(context, key) do
      nil -> {:error, error}
      value -> {:ok, value}
    end
  end

  defp to_decimal(%Decimal{} = value), do: {:ok, value}

  defp to_decimal(value) do
    {:ok, Decimal.new(to_string(value))}
  rescue
    Decimal.Error -> {:error, :invalid_position_sizing_value}
  end
end
