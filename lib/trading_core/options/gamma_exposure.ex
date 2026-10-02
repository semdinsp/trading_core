defmodule TradingCore.Options.GammaExposure do
  @moduledoc """
  Net dealer gamma exposure (GEX) of one option chain: the dollar gamma
  dealers are assumed to hold per 1% move in the underlying.

  Pure arithmetic over a chain the caller has already fetched and parsed
  (trading_signal pulls Cboe's delayed chains; see
  `TradingCore.Options.Occ.parse/1` for the symbols). Lives here so live
  signals and backtest replay compute the same number.

  ## Formula

  Per contract:

      gamma × open_interest × multiplier × spot² × 0.01

  `multiplier` is the contract multiplier (`opts[:multiplier]`, default
  100). `spot² × 0.01` turns per-$1 gamma into dollar gamma for a 1% move.

  ## Sign convention: an assumption, not an observation

  Calls count **positive** and puts **negative**, i.e. dealers are
  assumed long the calls customers sold them and short the puts
  customers bought. This is the standard convention in the GEX
  literature; open interest says nothing about who is on which side, so
  the sign of `net` is only as good as that assumption.

  ## Skipped rows

  A contract with `gamma <= 0`, `open_interest <= 0`, either value
  missing or unparseable, or a `right` other than `:call`/`:put` adds
  nothing and isn't counted in `contracts_used`. Live chains carry
  thousands of zero rows, so this is the normal case, not an error.

  ## Rounding

  Inputs may be `Decimal`, floats, integers or decimal strings. Sums are
  exact `Decimal`s, and every returned figure is rounded to whole
  dollars, so a caller can store or diff results without accumulating
  unbounded-precision Decimals (see `TradingCore.Signals`' moduledoc).

  ## Options

  - `:multiplier` — contract multiplier, default `100`; must be positive.
  - `:expiring_after` — a `Date`. Only contracts whose `:expiry` (a
    `Date`, as `TradingCore.Options.Occ.parse/1` returns) is **strictly
    after** it count. Pass the session date (US/Eastern) to get "ex-0DTE"
    exposure: same-day and already-expired contracts drop out. Under
    this option a contract with no `:expiry`, or one that isn't a `Date`,
    is skipped and not counted, since it can't be shown to qualify.
    Omitted, every expiry counts.

  Contracts may carry other keys too; they are ignored.
  """

  alias TradingCore.Regime.Decimals

  @type contract :: %{
          required(:right) => :call | :put,
          required(:gamma) => number() | Decimal.t() | String.t(),
          required(:open_interest) => number() | Decimal.t() | String.t(),
          optional(atom()) => term()
        }

  @type result :: %{
          net: Decimal.t(),
          calls: Decimal.t(),
          puts: Decimal.t(),
          contracts_used: non_neg_integer()
        }

  @default_multiplier 100
  @one_percent Decimal.new("0.01")

  @doc """
  Net gamma exposure of `contracts` at `spot`. See the moduledoc.

  `{:error, :invalid_spot}` unless `spot` is a positive number;
  `{:error, :invalid_multiplier}` unless `opts[:multiplier]` is;
  `{:error, :invalid_expiring_after}` when `opts[:expiring_after]` is
  given but isn't a `Date`. Never raises on malformed contracts; they
  are skipped.
  """
  @spec net(Enumerable.t(), number() | Decimal.t() | String.t(), keyword()) ::
          {:ok, result()}
          | {:error, :invalid_spot | :invalid_multiplier | :invalid_expiring_after}
  def net(contracts, spot, opts \\ []) do
    with {:spot, {:ok, spot}} <- {:spot, Decimals.parse(spot, :pos, [])},
         {:multiplier, {:ok, multiplier}} <-
           {:multiplier,
            Decimals.parse(Keyword.get(opts, :multiplier, @default_multiplier), :pos, [])},
         {:expiry, {:ok, included?}} <-
           {:expiry, expiry_filter(Keyword.get(opts, :expiring_after))} do
      scale = spot |> Decimal.mult(spot) |> Decimal.mult(@one_percent) |> Decimal.mult(multiplier)

      {calls, puts, used} =
        Enum.reduce(contracts, {Decimal.new(0), Decimal.new(0), 0}, fn contract,
                                                                       {calls, puts, used} ->
          case included?.(contract) && contribution(contract, scale) do
            {:call, gex} -> {Decimal.add(calls, gex), puts, used + 1}
            {:put, gex} -> {calls, Decimal.sub(puts, gex), used + 1}
            skip when skip in [:skip, false] -> {calls, puts, used}
          end
        end)

      {:ok,
       %{
         net: dollars(Decimal.add(calls, puts)),
         calls: dollars(calls),
         puts: dollars(puts),
         contracts_used: used
       }}
    else
      {:spot, :error} -> {:error, :invalid_spot}
      {:multiplier, :error} -> {:error, :invalid_multiplier}
      {:expiry, :error} -> {:error, :invalid_expiring_after}
    end
  end

  defp expiry_filter(nil), do: {:ok, fn _contract -> true end}

  defp expiry_filter(%Date{} = after_date) do
    {:ok,
     fn
       %{expiry: %Date{} = expiry} -> Date.compare(expiry, after_date) == :gt
       _contract -> false
     end}
  end

  defp expiry_filter(_invalid), do: :error

  # Unsigned dollar gamma for one usable contract, tagged by side.
  defp contribution(%{right: right} = contract, scale) when right in [:call, :put] do
    with {:ok, gamma} <- Decimals.parse(Map.get(contract, :gamma), :pos, []),
         {:ok, open_interest} <- Decimals.parse(Map.get(contract, :open_interest), :pos, []) do
      {right, gamma |> Decimal.mult(open_interest) |> Decimal.mult(scale)}
    else
      :error -> :skip
    end
  end

  defp contribution(_contract, _scale), do: :skip

  defp dollars(value), do: Decimal.round(value, 0)
end
