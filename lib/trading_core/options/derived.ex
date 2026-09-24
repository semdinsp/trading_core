defmodule TradingCore.Options.Derived do
  @moduledoc """
  Option snapshot values a rule needs but can't compute itself
  (`TradingCore.RuleEngine` only compares): the option's own bid/ask
  spread, daily decay as a share of premium, and leverage.

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
  The derived `run_*` values for one option tick, as a map of the keys
  whose inputs are present.

  `quote` is a map with `:bid` and `:ask`, or `nil`. `theta_per_day` must
  be per day: see "Theta must already be PER DAY" in the moduledoc.
  """
  @spec values(
          number() | nil,
          number() | nil,
          number() | nil,
          number() | nil,
          %{optional(:bid) => number() | nil, optional(:ask) => number() | nil} | nil
        ) :: %{String.t() => number()}
  def values(price, underlying, delta, theta_per_day, quote) do
    priced? = is_number(price) and price > 0

    [
      {"run_theta_pct", (priced? and is_number(theta_per_day)) && theta_per_day / price * 100},
      {"run_lambda",
       (priced? and is_number(delta) and is_number(underlying)) && delta * underlying / price}
    ]
    |> Kernel.++(spread_values(quote))
    |> Enum.filter(fn {_k, v} -> is_number(v) end)
    |> Map.new()
  end

  defp spread_values(%{bid: bid, ask: ask})
       when is_number(bid) and is_number(ask) and bid > 0 and ask >= bid do
    mid = (bid + ask) / 2
    [{"run_spread", ask - bid}, {"run_spread_pct", (ask - bid) / mid * 100}]
  end

  defp spread_values(_quote), do: []
end
