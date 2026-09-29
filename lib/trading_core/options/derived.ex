defmodule TradingCore.Options.Derived do
  @moduledoc """
  Option snapshot values a rule needs but can't compute itself
  (`TradingCore.RuleEngine` only compares): the option's own bid/ask
  spread, daily decay as a share of premium, leverage, and the premium's
  expected daily move.

  Moved here from `TradingOptionsSim.ContractMonitor.derived_values/5` so
  `trading_options_sim` and `trading_live` compute identical values. A
  strategy's rule tree is promoted from one to the other byte-for-byte,
  so the same inputs must give the same numbers in both.

  | key | value |
  |---|---|
  | `run_spread` | `ask - bid`, per share |
  | `run_spread_pct` | `(ask - bid) / mid * 100`: roughly what a round trip costs, as a % of the premium |
  | `run_theta_pct` | `theta_per_day / price * 100` (negative for a long) |
  | `run_lambda` | `delta * underlying / price`: % option move per 1% underlying move (elasticity) |
  | `run_premium_daily_vol` | `implied_vol / sqrt(252) * abs(run_lambda)`: the premium's expected one-day move, as a fraction of the premium (`values/6` only) |

  `run_premium_daily_vol` is the underlying's implied daily vol (annual
  IV over √252) scaled by the option's leverage. E.g. IV 13%, lambda 20:
  `0.13 / 15.87 * 20 = 0.16`, a 16% daily premium move. It is the
  `daily_vol` a `"volatility_multiple"` stop is sized from (see
  `TradingCore.RiskControls.resolve_levels/4`), and forward-looking, so
  it needs no bar history. Moved here from
  `TradingOptionsSim.ContractMonitor.premium_vol_values/2` on 2026-09-29
  so `trading_live` can size the same stops for a promoted strategy.
  `implied_vol` must be **annual**, as a fraction (`0.13`, not `13`):
  IBKR's `TickOptionComputation` IV and Black-Scholes IV both are. A
  per-day IV would make this about 16x too small. `abs(lambda)` is used
  because a put's lambda is negative but its premium still moves.

  The key names are the ones stored in live strategy rule trees. Renaming
  one would break those rules silently, since a missing key fails closed.

  ## Theta must already be PER DAY

  **`theta_per_day` must be per day.** IBKR's model theta is per day.
  Black-Scholes theta (e.g. `trading_options_sim`'s pricer) is per YEAR,
  and the caller must divide it by 365 before calling `values/5`. Passing
  a per-year theta makes `run_theta_pct` 365 times too large, and nothing
  here can detect that.

  ## Absent means unknown, never zero

  A key is **omitted**, not zeroed, when its inputs are missing, or when
  `price` is missing or `<= 0`. The spread keys need a two-sided quote
  with `bid > 0` and `ask >= bid`. IBKR sends a closed book as bid/ask
  `-1.0`, which means "no market", not a spread. `TradingCore.RuleEngine`
  fails closed on a missing key, which is the right answer for an
  unknown value.
  """

  @doc """
  `values/6` without `implied_vol`: every key except
  `run_premium_daily_vol`. Kept so existing callers are unchanged.
  """
  @spec values(
          number() | nil,
          number() | nil,
          number() | nil,
          number() | nil,
          %{optional(:bid) => number() | nil, optional(:ask) => number() | nil} | nil
        ) :: %{String.t() => number()}
  def values(price, underlying, delta, theta_per_day, quote),
    do: values(price, underlying, delta, theta_per_day, quote, nil)

  @doc """
  The derived `run_*` values for one option tick, as a map of the keys
  whose inputs are present.

  `quote` is a map with `:bid` and `:ask`, or `nil`. `theta_per_day` must
  be per day: see "Theta must already be PER DAY" in the moduledoc.
  `implied_vol` is annual, as a fraction; `run_premium_daily_vol` is
  computed from it and this tick's own `run_lambda`.
  """
  @spec values(
          number() | nil,
          number() | nil,
          number() | nil,
          number() | nil,
          %{optional(:bid) => number() | nil, optional(:ask) => number() | nil} | nil,
          number() | nil
        ) :: %{String.t() => number()}
  def values(price, underlying, delta, theta_per_day, quote, implied_vol) do
    priced? = is_number(price) and price > 0

    lambda =
      priced? and is_number(delta) and is_number(underlying) && delta * underlying / price

    [
      {"run_theta_pct", priced? and is_number(theta_per_day) && theta_per_day / price * 100},
      {"run_lambda", lambda},
      {"run_premium_daily_vol", premium_daily_vol(implied_vol, lambda)}
    ]
    |> Kernel.++(spread_values(quote))
    |> Enum.filter(fn {_k, v} -> is_number(v) end)
    |> Map.new()
  end

  @doc """
  The premium's expected one-day move as a fraction of the premium:
  `implied_vol / sqrt(252) * abs(lambda)`. `nil` when `implied_vol` is
  missing or not positive, or `lambda` is missing or zero — absent, so a
  rule on it fails closed and a `"volatility_multiple"` stop falls back
  to `percent_of_entry`.
  """
  @spec premium_daily_vol(number() | nil, number() | nil | false) :: float() | nil
  def premium_daily_vol(implied_vol, lambda)
      when is_number(implied_vol) and is_number(lambda) and implied_vol > 0 and lambda != 0,
      do: implied_vol / :math.sqrt(252) * abs(lambda)

  def premium_daily_vol(_implied_vol, _lambda), do: nil

  @doc """
  `premium_daily_vol/2` as a snapshot fragment:
  `%{"run_premium_daily_vol" => value}`, or `%{}` when it is unknown.
  The same shape `TradingOptionsSim.ContractMonitor.premium_vol_values/2`
  returned, for a caller merging it into a snapshot.
  """
  @spec premium_vol_values(number() | nil, number() | nil) :: %{String.t() => float()}
  def premium_vol_values(implied_vol, lambda) do
    case premium_daily_vol(implied_vol, lambda) do
      nil -> %{}
      vol -> %{"run_premium_daily_vol" => vol}
    end
  end

  defp spread_values(%{bid: bid, ask: ask})
       when is_number(bid) and is_number(ask) and bid > 0 and ask >= bid do
    mid = (bid + ask) / 2
    [{"run_spread", ask - bid}, {"run_spread_pct", (ask - bid) / mid * 100}]
  end

  defp spread_values(_quote), do: []
end
