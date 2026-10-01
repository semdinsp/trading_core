defmodule TradingCore.Regime.Exposure do
  @moduledoc """
  Market-direction and risk arithmetic the allocation gate needs: which way
  a position leans against the market, its beta-weighted dollars, how much
  it risks per unit, and per-bucket totals over a book.

  Pure, `Decimal` in and out. Inputs accept the usual
  `TradingCore.Signals.sample/0` union (`Decimal | float | integer |
  String`). Every Decimal returned is rounded — risk per unit to 6 places,
  dollar totals to 2 — because callers keep these in long-lived state
  (the guardian's book), where unrounded `Decimal.div/2`/`Decimal.mult/2`
  results have caused memory blowups in this workspace before.

  ## Direction × beta

  `"short"` flips the sign of beta. A short of an inverse ETF (SQQQ,
  beta −3) is therefore `:long_market` — it gains when the market rises.
  """

  alias TradingCore.Signals

  @type direction :: String.t() | :long | :short
  @type market_side :: :long_market | :short_market | :flat

  @risk_precision 6
  @dollar_precision 2

  @doc "Market side of a position: `direction` × sign of `beta`; beta 0 ⇒ `:flat`."
  @spec sign(direction(), Signals.sample()) :: market_side()
  def sign(direction, beta) do
    product = direction_sign(direction) * decimal_sign(to_decimal(beta))

    cond do
      product > 0 -> :long_market
      product < 0 -> :short_market
      true -> :flat
    end
  end

  @doc "Signed beta-weighted dollars: `±beta × |notional|`, rounded to 2 places."
  @spec beta_dollars(direction(), Signals.sample(), Signals.sample()) :: Decimal.t()
  def beta_dollars(direction, beta, notional) do
    notional
    |> to_decimal()
    |> Decimal.abs()
    |> Decimal.mult(to_decimal(beta))
    |> Decimal.mult(direction_sign(direction))
    |> Decimal.round(@dollar_precision)
  end

  @doc """
  Dollars at risk per unit (share or contract), per plan decision D1.

  - `stop_price` and `base_price` both present ⇒
    `{:ok, |base − stop| × multiplier, :stop}` — the same formula as
    trading_live's `risk_at_entry`.
  - otherwise `daily_vol` and `base_price` present ⇒
    `{:ok, daily_vol × base × multiplier, :daily_vol}` (a 1-day 1-σ move).
  - otherwise `{:error, :missing_risk_input}`.

  `multiplier` defaults to 1. A branch whose result is zero or negative
  (a stop equal to base, a zero vol) is treated as not computable and
  falls through, since zero risk per unit would let the gate size
  without limit.
  """
  @spec risk_per_unit(map()) ::
          {:ok, Decimal.t(), :stop | :daily_vol} | {:error, :missing_risk_input}
  def risk_per_unit(inputs) when is_map(inputs) do
    base = Map.get(inputs, :base_price)
    stop = Map.get(inputs, :stop_price)
    vol = Map.get(inputs, :daily_vol)
    multiplier = to_decimal(Map.get(inputs, :multiplier) || 1)

    from_stop =
      if present?(base) and present?(stop) do
        to_decimal(base) |> Decimal.sub(to_decimal(stop)) |> Decimal.abs()
      end

    from_vol =
      if present?(base) and present?(vol) do
        Decimal.mult(to_decimal(vol), to_decimal(base))
      end

    cond do
      positive?(from_stop, multiplier) -> {:ok, scale(from_stop, multiplier), :stop}
      positive?(from_vol, multiplier) -> {:ok, scale(from_vol, multiplier), :daily_vol}
      true -> {:error, :missing_risk_input}
    end
  end

  @doc """
  Totals per bucket and for the whole book. Each position is
  `%{bucket, open_risk, notional, beta_dollars}`; the result is
  `%{bucket => totals, :portfolio => totals}` where totals are
  `%{open_risk, gross_notional, count, net_beta_dollars}`. Gross notional
  sums absolute notionals; net beta dollars keeps the sign. Dollar values
  are rounded to 2 places. An empty book has a zero `:portfolio` entry.
  """
  @spec bucket_totals([map()]) :: %{(String.t() | :portfolio) => map()}
  def bucket_totals(positions) do
    positions
    |> Enum.reduce(%{portfolio: zero()}, fn position, acc ->
      acc
      |> Map.update(position.bucket, add(zero(), position), &add(&1, position))
      |> Map.update!(:portfolio, &add(&1, position))
    end)
    |> Map.new(fn {bucket, totals} -> {bucket, round_totals(totals)} end)
  end

  ## ---------------------------------------------------------------------

  defp zero do
    %{
      open_risk: Decimal.new(0),
      gross_notional: Decimal.new(0),
      count: 0,
      net_beta_dollars: Decimal.new(0)
    }
  end

  defp add(totals, position) do
    %{
      open_risk: Decimal.add(totals.open_risk, to_decimal(position.open_risk)),
      gross_notional:
        Decimal.add(totals.gross_notional, Decimal.abs(to_decimal(position.notional))),
      count: totals.count + 1,
      net_beta_dollars: Decimal.add(totals.net_beta_dollars, to_decimal(position.beta_dollars))
    }
  end

  defp round_totals(totals) do
    %{
      totals
      | open_risk: Decimal.round(totals.open_risk, @dollar_precision),
        gross_notional: Decimal.round(totals.gross_notional, @dollar_precision),
        net_beta_dollars: Decimal.round(totals.net_beta_dollars, @dollar_precision)
    }
  end

  defp scale(value, multiplier),
    do: value |> Decimal.mult(multiplier) |> Decimal.round(@risk_precision)

  defp positive?(nil, _multiplier), do: false

  defp positive?(value, multiplier),
    do: Decimal.compare(scale(value, multiplier), 0) == :gt

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true

  defp direction_sign(d) when d in ["long", :long], do: 1
  defp direction_sign(d) when d in ["short", :short], do: -1

  defp decimal_sign(d) do
    case Decimal.compare(d, 0) do
      :gt -> 1
      :lt -> -1
      :eq -> 0
    end
  end

  defp to_decimal(%Decimal{} = value), do: value
  defp to_decimal(value) when is_float(value), do: Decimal.from_float(value)
  defp to_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp to_decimal(value) when is_binary(value), do: Decimal.new(value)
end
