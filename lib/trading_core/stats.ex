defmodule TradingCore.Stats do
  @moduledoc """
  Shared statistical helpers for strategy performance metrics.

  ## Why this module exists

  Three different z-constants were in use across `trading_system` and
  `trading_live` for what every call site documented as a "90% bound":
  1.645 (one-sided 95% / two-sided 90%) in `trading_system`'s universe
  metrics, and 1.2816 (one-sided 90% / two-sided 80%) in both apps'
  `expectancy_by_regime`. Both are individually defensible critical
  values, but having both under the same field name `lcb90` in the same
  system means a version's `lcb90` from one payload and a bucket's
  `lcb90` from another were not the same kind of number, with nothing in
  either payload saying so.

  Standardised on `z = 1.645` (two-sided 90%) — what the universe
  metrics (the widest-read surface, and the one promotion gates run on)
  already used, so this changes the fewest published numbers and moves
  in the conservative direction everywhere else.
  """

  @doc """
  z for a **90% two-sided** normal confidence interval (one-sided 95%).

  This is the single source of truth for the multiplier behind every
  field named `lcb90` / `ucb90` anywhere in the system. Do not inline
  this value at a call site.

  If a bound at a different confidence level is ever needed, add a named
  constant and a distinctly named field (`lcb80`, `lcb95`) — never reuse
  `lcb90` for it.
  """
  @z_90_two_sided 1.645

  @spec z_90_two_sided() :: float()
  def z_90_two_sided, do: @z_90_two_sided

  @doc """
  Returns `{lcb, ucb}` — the 90% two-sided confidence interval on a
  sample mean, given its standard deviation `sd` and sample size `n`.

  Returns `{nil, nil}` when `n < 2` (no standard error is estimable from
  a single observation) or when `mean`/`sd` is `nil`. Callers must render
  `nil` as "—", never as `0.0` — a missing bound and a bound that
  happens to sit at zero are different facts, and one of them passes a
  promotion gate.

  Takes and returns `Decimal.t()`, matching how the rest of this system
  carries money/R values — the `:math.sqrt/1` step is done on values
  converted to `float` internally so callers never each invent their own
  coercion.

  ## Examples

      iex> {lcb, ucb} = TradingCore.Stats.confidence_bounds(Decimal.new("0.36581"), Decimal.new("1.19838"), 39)
      iex> Decimal.round(lcb, 5)
      Decimal.new("0.05014")
      iex> Decimal.round(ucb, 5)
      Decimal.new("0.68148")
  """
  @spec confidence_bounds(Decimal.t() | nil, Decimal.t() | nil, non_neg_integer() | nil) ::
          {Decimal.t() | nil, Decimal.t() | nil}
  def confidence_bounds(nil, _sd, _n), do: {nil, nil}
  def confidence_bounds(_mean, nil, _n), do: {nil, nil}
  def confidence_bounds(_mean, _sd, n) when is_nil(n) or n < 2, do: {nil, nil}

  def confidence_bounds(%Decimal{} = mean, %Decimal{} = sd, n) when is_integer(n) do
    sd_float = Decimal.to_float(sd)
    margin = @z_90_two_sided * sd_float / :math.sqrt(n)
    margin_decimal = Decimal.from_float(margin)

    {Decimal.sub(mean, margin_decimal), Decimal.add(mean, margin_decimal)}
  end
end
