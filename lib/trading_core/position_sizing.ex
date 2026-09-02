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

  ## Fractional shares

  `volatility_target`'s `target_dollar_volatility / (daily_vol * price)`
  division essentially never lands on a whole number. IBKR's API rejects
  a fractional-quantity order outright ("Fractional-sized order cannot be
  placed via API" — confirmed live, `trading_live` submitting real
  orders after `target_dollar_volatility` was lowered to $10, which made
  a non-integer result far more likely than at a larger budget) even
  though IBKR's desktop TWS client supports fractional shares for many US
  names; `trading_system` never submits a real order at all (paper-only),
  so this restriction is specific to a caller that actually places live
  orders. `context[:fractional_shares_enabled]` (boolean, required)
  controls this: `true` returns the raw division result unchanged,
  `false` rounds UP to the nearest whole share (`Decimal.round(qty, 0,
  :up)` — never DOWN, so a share count of `0` is never returned; rounding
  up means the actual dollar exposure taken can run slightly over
  `target_dollar_volatility`, accepted as the simpler tradeoff). Each app
  supplies its own `fractional_shares_enabled` app setting (default
  `false` in both, since neither app can safely rely on live fractional
  order support yet) — see `TradingLive.PositionSizing`/
  `TradingSystem.Trading.PositionSizing`'s own callers for where it's
  read and threaded in.
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
    `Decimal.new/1` accepts). `context[:fractional_shares_enabled]`
    (boolean, required) controls whether the raw division result is
    returned as-is (`true`) or rounded UP to the nearest whole share
    (`false`) — see the moduledoc's "Fractional shares" section.

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
         {:ok, fractional_shares_enabled} <-
           fetch_context(
             context,
             :fractional_shares_enabled,
             :fractional_shares_enabled_required
           ),
         {:ok, daily_vol} <- to_decimal(daily_vol),
         {:ok, price} <- to_decimal(price),
         {:ok, target_dollar_volatility} <- to_decimal(target_dollar_volatility),
         false <- Decimal.eq?(daily_vol, 0),
         false <- Decimal.eq?(price, 0) do
      qty = Decimal.div(target_dollar_volatility, Decimal.mult(daily_vol, price))

      qty = if fractional_shares_enabled, do: qty, else: Decimal.round(qty, 0, :up)

      {:ok, qty}
    else
      true -> {:error, :daily_volatility_unavailable}
      {:error, _reason} = error -> error
    end
  end

  def calculate_qty(_config, _context), do: {:error, :unknown_sizing_method}

  @doc """
  Shared glue for the `"volatility_target"` method: resolves `:symbol` and
  `:price` out of `context`, calls `daily_volatility_fn` (an app's own hub
  RPC — `trading_system`'s `Bus.get_daily_volatility/2`, `trading_live`'s
  `Volatility.daily_volatility/2`, etc.) to get `daily_vol`, then delegates
  to `calculate_qty/2` for the actual arithmetic.

  Extracted here because both callers had identical fetch/delegate control
  flow around their own RPC — only the RPC itself and its context/error
  needs (:exchange) differ per app, so both are still supplied by the
  caller rather than living in this I/O-free module.

  `context` must include `:symbol`, `:price`, and `:target_dollar_volatility`;
  `:exchange` is optional (passed through to `daily_volatility_fn` as `nil`
  if absent, same as both existing callers already do via `Map.get/2`).
  `daily_volatility_fn` must return `{:ok, Decimal.t()} | {:error, term()}`
  — any error it returns is normalized to `:daily_volatility_unavailable`,
  matching both callers' prior behavior of not leaking RPC-specific error
  reasons into the sizing result.

  `opts` lets each caller keep its own pre-existing error atom for a
  missing price — `trading_system` returns `:price_unavailable` (shared
  with its other sizing methods' own missing-price case) while
  `trading_live` returns `:price_required`; both are already covered by
  each app's own tests, so this helper doesn't force either one to change
  its public error contract. Defaults to `:price_required`.
  """
  @spec resolve_volatility_target(
          map(),
          map(),
          (String.t(), String.t() | nil ->
             {:ok, Decimal.t()} | {:error, term()}),
          keyword()
        ) ::
          {:ok, Decimal.t()} | {:error, atom()}
  def resolve_volatility_target(config, context, daily_volatility_fn, opts \\ [])
      when is_function(daily_volatility_fn, 2) do
    price_error = Keyword.get(opts, :price_error, :price_required)

    with {:ok, symbol} <- fetch_context(context, :symbol, :symbol_required),
         {:ok, price} <- fetch_context(context, :price, price_error),
         {:ok, target_dollar_volatility} <-
           fetch_context(
             context,
             :target_dollar_volatility,
             :target_dollar_volatility_required
           ),
         {:ok, fractional_shares_enabled} <-
           fetch_context(
             context,
             :fractional_shares_enabled,
             :fractional_shares_enabled_required
           ),
         exchange <- Map.get(context, :exchange),
         {:ok, daily_vol} <- daily_volatility(daily_volatility_fn, symbol, exchange) do
      calculate_qty(config, %{
        daily_vol: daily_vol,
        price: price,
        target_dollar_volatility: target_dollar_volatility,
        fractional_shares_enabled: fractional_shares_enabled
      })
    end
  end

  defp daily_volatility(daily_volatility_fn, symbol, exchange) do
    case daily_volatility_fn.(symbol, exchange) do
      {:ok, daily_vol} -> {:ok, daily_vol}
      {:error, _reason} -> {:error, :daily_volatility_unavailable}
    end
  end

  @doc """
  Same as `resolve_volatility_target/4`, but also returns the
  `daily_vol` figure used to compute `qty` — `{:ok, qty, daily_vol}`
  instead of `{:ok, qty}`. Added for `trading_system`'s entry-reporting
  fields (`StrategyRun.entry_vol_estimate`), which need to persist the
  vol estimate a sizing decision was actually made against, not just the
  resulting quantity — see that field's own doc for why this can't be
  reconstructed after the fact. A strictly additive function, not a
  replacement: `resolve_volatility_target/4` itself is unchanged, so
  `trading_live`'s existing caller (`TradingLive.PositionSizing`) is
  unaffected by this addition.
  """
  @spec resolve_volatility_target_with_estimate(
          map(),
          map(),
          (String.t(), String.t() | nil -> {:ok, Decimal.t()} | {:error, term()}),
          keyword()
        ) :: {:ok, Decimal.t(), Decimal.t()} | {:error, atom()}
  def resolve_volatility_target_with_estimate(config, context, daily_volatility_fn, opts \\ [])
      when is_function(daily_volatility_fn, 2) do
    price_error = Keyword.get(opts, :price_error, :price_required)

    with {:ok, symbol} <- fetch_context(context, :symbol, :symbol_required),
         {:ok, price} <- fetch_context(context, :price, price_error),
         {:ok, target_dollar_volatility} <-
           fetch_context(
             context,
             :target_dollar_volatility,
             :target_dollar_volatility_required
           ),
         {:ok, fractional_shares_enabled} <-
           fetch_context(
             context,
             :fractional_shares_enabled,
             :fractional_shares_enabled_required
           ),
         exchange <- Map.get(context, :exchange),
         {:ok, daily_vol} <- daily_volatility(daily_volatility_fn, symbol, exchange),
         {:ok, qty} <-
           calculate_qty(config, %{
             daily_vol: daily_vol,
             price: price,
             target_dollar_volatility: target_dollar_volatility,
             fractional_shares_enabled: fractional_shares_enabled
           }) do
      {:ok, qty, daily_vol}
    end
  end

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
