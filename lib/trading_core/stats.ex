defmodule TradingCore.Stats do
  @moduledoc """
  Shared statistical helpers for strategy performance metrics.

  ## Naming law

  A field named `lcbNN` / `ucbNN` is the **one-sided NN% bound**. `lcb90`
  means "90% confident the true mean exceeds this." It does not mean
  "the lower end of a 90% interval" — that object is `lcb95`, and
  conflating the two is what originally put three different multipliers
  in this system under one name (see `confidence_bounds/3`'s own doc for
  that history).

  Never introduce a bound field whose name does not carry its level.

  ## Why one-sided, not an interval

  Nothing in this system ever uses `{lcb, ucb}` as an interval. Every
  consumer asks a one-sided question: `/candidates` Gate 2 tests
  `lcb90 > 0` ("is expectancy positive?"); `/performance/review`
  criterion A tests `ucb90 < 0` ("is expectancy negative?"). Under a
  one-sided reading, the two z-constants already in the codebase
  (1.2816 and 1.645) are both correct and neither needs to change — the
  collision that motivated `confidence_bounds/3` was never in the
  arithmetic, it was in the shared name `lcb90` covering two different
  levels.
  """

  # One-sided critical values. Do not "improve" 1.645 to the more precise
  # 1.6448536 — the coarser literal is what every already-published
  # value (e.g. universe metrics' lcb90/ucb90, now this module's
  # bounds(..., :p95)) was computed with; tightening it would move
  # published values in the 5th decimal for no benefit, and would make it
  # impossible to tell whether a changed number came from a refactor or
  # a rounding change. A precision change, if ever wanted, is its own
  # separate, separately-verified commit.
  @z %{p90: 1.2816, p95: 1.645}

  @doc "Critical z for a one-sided bound at `:p90` or `:p95`."
  @spec z(:p90 | :p95) :: float()
  def z(level) when is_map_key(@z, level), do: Map.fetch!(@z, level)

  @doc """
  One-sided lower bound on a sample mean at `level` (`:p90` or `:p95`) —
  e.g. `lower_bound(mean, sd, n, :p90)` backs a field named `lcb90`.

  Returns `nil` when `n < 2` (no standard error is estimable from a
  single observation) or when `mean`/`sd` is `nil`. Callers must render
  `nil` as "—", never as `0.0` — a bound of exactly `0.0` reads as "just
  failed to clear," a materially different statement from "not
  computable," and one of those passes a promotion gate.

  Takes and returns `Decimal.t()`, matching how the rest of this system
  carries money/R values — the `:math.sqrt/1` step is done on a value
  converted to `float` internally so callers never each invent their own
  coercion.
  """
  @spec lower_bound(Decimal.t() | nil, Decimal.t() | nil, non_neg_integer() | nil, :p90 | :p95) ::
          Decimal.t() | nil
  def lower_bound(mean, sd, n, level), do: shift(mean, sd, n, level, -1)

  @doc "One-sided upper bound on a sample mean at `level` — e.g. `upper_bound(mean, sd, n, :p90)` backs a field named `ucb90`. Same `nil` rules as `lower_bound/4`."
  @spec upper_bound(Decimal.t() | nil, Decimal.t() | nil, non_neg_integer() | nil, :p90 | :p95) ::
          Decimal.t() | nil
  def upper_bound(mean, sd, n, level), do: shift(mean, sd, n, level, 1)

  @doc """
  `{lower, upper}` at the same one-sided `level` — the pair most callers
  want, e.g. `bounds(mean, sd, n, :p90)` backs a payload's `{lcb90,
  ucb90}`.

  These are two independent one-sided statements, not a `level`%
  interval — the region between them carries roughly `2 * level - 1`
  coverage (e.g. `:p90` gives ~80% between the pair). Use each bound for
  its own one-sided question; do not describe the pair as an interval.
  """
  @spec bounds(Decimal.t() | nil, Decimal.t() | nil, non_neg_integer() | nil, :p90 | :p95) ::
          {Decimal.t() | nil, Decimal.t() | nil}
  def bounds(mean, sd, n, level),
    do: {lower_bound(mean, sd, n, level), upper_bound(mean, sd, n, level)}

  @doc """
  Returns `{lcb, ucb}` on a sample mean at the one-sided 95% level —
  equivalent to `bounds(mean, sd, n, :p95)`.

  Originally documented as a "90% two-sided" interval; every real
  consumer of this pair asks a one-sided question (see this module's own
  moduledoc), so `lcb90`/`ucb90` fields backed by this function were
  actually one-sided-95% bounds wearing a name that said 90%. Kept, and
  its arithmetic is unchanged — the lower endpoint of a two-sided 90%
  interval *is* the one-sided 95% lower bound, so this delegation moves
  no published value.
  """
  @deprecated "Use bounds/4 with an explicit level (:p90 or :p95)"
  @spec confidence_bounds(Decimal.t() | nil, Decimal.t() | nil, non_neg_integer() | nil) ::
          {Decimal.t() | nil, Decimal.t() | nil}
  def confidence_bounds(mean, sd, n), do: bounds(mean, sd, n, :p95)

  @doc """
  z for a one-sided 95% bound — equivalent to `z(:p95)`.
  """
  @deprecated "Use z/1 with an explicit level (:p90 or :p95)"
  @spec z_90_two_sided() :: float()
  def z_90_two_sided, do: z(:p95)

  defp shift(nil, _sd, _n, _level, _sign), do: nil
  defp shift(_mean, nil, _n, _level, _sign), do: nil
  defp shift(_mean, _sd, n, _level, _sign) when is_nil(n) or n < 2, do: nil

  defp shift(%Decimal{} = mean, %Decimal{} = sd, n, level, sign) when is_integer(n) do
    sd_float = Decimal.to_float(sd)
    margin = sign * z(level) * sd_float / :math.sqrt(n)

    Decimal.add(mean, Decimal.from_float(margin))
  end
end
