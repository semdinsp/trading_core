defmodule TradingCore.Regime.Exposure do
  @moduledoc """
  Market-direction and risk arithmetic the allocation gate needs: which way
  a position leans against the market, its beta-weighted dollars, how much
  it risks per unit, and per-bucket totals over a book.

  Pure, `Decimal` in and out. Inputs accept the usual
  `TradingCore.Signals.sample/0` union (`Decimal | float | integer |
  String`). Every Decimal returned is rounded — risk per unit to 6 places
  (rounded *up*, so risk is never understated), dollar totals to 2 —
  because callers keep these in long-lived state (the guardian's book),
  where unrounded `Decimal.div/2`/`Decimal.mult/2` results have caused
  memory blowups in this workspace before.

  None of these functions raise on bad input; see each function for what
  an unparseable value becomes.

  ## Direction × beta

  `"short"` flips the sign of beta. A short of an inverse ETF (SQQQ,
  beta −3) is therefore `:long_market` — it gains when the market rises.
  """

  alias TradingCore.Regime.Decimals
  alias TradingCore.Signals

  @type direction :: String.t() | :long | :short
  @type market_side :: :long_market | :short_market | :flat

  @risk_precision 6
  @dollar_precision 2

  @doc """
  Market side of a position: `direction` × sign of `beta`; beta 0 ⇒
  `:flat`. `direction` is `"long"`/`"short"` (any case) or `:long`/`:short`.
  An unrecognized direction or an unparseable/nil beta is `:flat` — no
  known market exposure — so an exposure selector never matches it.
  """
  @spec sign(direction(), Signals.sample() | nil) :: market_side()
  def sign(direction, beta) do
    product =
      case Decimals.parse(beta) do
        {:ok, beta} -> direction_sign(direction) * decimal_sign(beta)
        :error -> 0
      end

    cond do
      product > 0 -> :long_market
      product < 0 -> :short_market
      true -> :flat
    end
  end

  @doc """
  Signed beta-weighted dollars: `±beta × |notional|`, rounded to 2 places.
  Zero when the direction is unrecognized or beta/notional don't parse.
  """
  @spec beta_dollars(direction(), Signals.sample() | nil, Signals.sample() | nil) :: Decimal.t()
  def beta_dollars(direction, beta, notional) do
    with {:ok, beta} <- Decimals.parse(beta),
         {:ok, notional} <- Decimals.parse(notional) do
      notional
      |> Decimal.abs()
      |> Decimal.mult(beta)
      |> Decimal.mult(direction_sign(direction))
      |> Decimal.round(@dollar_precision)
    else
      :error -> Decimal.round(Decimal.new(0), @dollar_precision)
    end
  end

  @doc """
  Dollars at risk per unit (share or contract), per plan decision D1.

  - `stop_price` and `base_price` both present ⇒
    `{:ok, |base − stop| × multiplier, :stop}` — the same formula as
    trading_live's `risk_at_entry`.
  - otherwise `daily_vol` and `base_price` present ⇒
    `{:ok, daily_vol × base × multiplier, :daily_vol}` (a 1-day 1-σ move).
  - otherwise `{:error, :missing_risk_input}`.

  `multiplier` defaults to 1 when nil; any other value that isn't a
  positive number is `{:error, :missing_risk_input}`. A value that doesn't
  parse counts as absent. A branch whose result is zero (a stop equal to
  base, a zero vol) is treated as not computable and falls through, since
  zero risk per unit would let the gate size without limit — the returned
  basis says which branch was used, so the caller can record it.
  """
  @spec risk_per_unit(map()) ::
          {:ok, Decimal.t(), :stop | :daily_vol} | {:error, :missing_risk_input}
  def risk_per_unit(inputs) when is_map(inputs) do
    base = parsed(inputs, :base_price)
    stop = parsed(inputs, :stop_price)
    vol = parsed(inputs, :daily_vol)

    from_stop = if base && stop, do: base |> Decimal.sub(stop) |> Decimal.abs()
    from_vol = if base && vol, do: Decimal.mult(vol, base)

    with {:ok, multiplier} <- Decimals.parse(Map.get(inputs, :multiplier) || 1, :pos, []) do
      cond do
        positive?(from_stop, multiplier) -> {:ok, scale(from_stop, multiplier), :stop}
        positive?(from_vol, multiplier) -> {:ok, scale(from_vol, multiplier), :daily_vol}
        true -> {:error, :missing_risk_input}
      end
    else
      :error -> {:error, :missing_risk_input}
    end
  end

  def risk_per_unit(_inputs), do: {:error, :missing_risk_input}

  @doc """
  Totals per bucket and for the whole book. Each position is
  `%{bucket, open_risk, notional, beta_dollars}`; the result is
  `%{bucket => totals, :portfolio => totals}` where totals are
  `%{open_risk, gross_notional, count, net_beta_dollars,
  missing_risk_count}`. Gross notional sums absolute notionals; net beta
  dollars keeps the sign. Dollar values are rounded to 2 places. An empty
  book has a zero `:portfolio` entry.

  A position whose `open_risk` (or `notional`/`beta_dollars`) is nil or
  doesn't parse contributes zero to that sum. Because zero risk would
  understate the book, such positions are also counted in
  `missing_risk_count`, so the caller can refuse to gate against an
  incomplete book instead of silently under-counting it.
  """
  @spec bucket_totals([map()]) :: %{(String.t() | :portfolio) => map()}
  def bucket_totals(positions) do
    positions
    |> Enum.reduce(%{portfolio: zero()}, fn position, acc ->
      acc
      |> Map.update(Map.get(position, :bucket), add(zero(), position), &add(&1, position))
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
      net_beta_dollars: Decimal.new(0),
      missing_risk_count: 0
    }
  end

  defp add(totals, position) do
    risk = Decimals.parse(Map.get(position, :open_risk), :non_neg, [])

    %{
      open_risk: Decimal.add(totals.open_risk, or_zero(risk)),
      gross_notional:
        Decimal.add(
          totals.gross_notional,
          Decimal.abs(or_zero(Decimals.parse(Map.get(position, :notional))))
        ),
      count: totals.count + 1,
      net_beta_dollars:
        Decimal.add(
          totals.net_beta_dollars,
          or_zero(Decimals.parse(Map.get(position, :beta_dollars)))
        ),
      missing_risk_count: totals.missing_risk_count + if(risk == :error, do: 1, else: 0)
    }
  end

  defp or_zero({:ok, d}), do: d
  defp or_zero(:error), do: Decimal.new(0)

  defp round_totals(totals) do
    %{
      totals
      | open_risk: Decimal.round(totals.open_risk, @dollar_precision),
        gross_notional: Decimal.round(totals.gross_notional, @dollar_precision),
        net_beta_dollars: Decimal.round(totals.net_beta_dollars, @dollar_precision)
    }
  end

  defp parsed(inputs, key) do
    case Decimals.parse(Map.get(inputs, key)) do
      {:ok, d} -> d
      :error -> nil
    end
  end

  defp scale(value, multiplier),
    do: value |> Decimal.mult(multiplier) |> Decimal.round(@risk_precision, :ceiling)

  defp positive?(nil, _multiplier), do: false

  defp positive?(value, multiplier),
    do: Decimal.compare(scale(value, multiplier), 0) == :gt

  defp direction_sign(d) when d in [:long, :short], do: direction_sign(Atom.to_string(d))

  defp direction_sign(d) when is_binary(d) do
    case String.downcase(String.trim(d)) do
      "long" -> 1
      "short" -> -1
      _ -> 0
    end
  end

  defp direction_sign(_), do: 0

  defp decimal_sign(d) do
    case Decimal.compare(d, 0) do
      :gt -> 1
      :lt -> -1
      :eq -> 0
    end
  end
end
