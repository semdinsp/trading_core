defmodule TradingCore.Decimals do
  @moduledoc """
  Decimal helpers shared across trading_core.

  ## Rounding to an integer without raising (decimal >= 3.2.0)

  From 3.2.0 (the fix for EEF-CVE-2026-97853), `Decimal.round/3` raises
  `Decimal.Error` (`invalid_operation`) when the result has more digits
  than the context precision (34 by default). Rounding a value of 1e34 or
  more to 0 places therefore raises, where 3.1.1 returned the big
  integer. `round_integral/2` returns such a value unchanged instead:
  with a non-negative exponent it is already an integer, so rounding
  could not change it. Every other input rounds exactly as
  `Decimal.round(d, 0, mode)` did, so results are unchanged wherever
  3.1.1 didn't raise.
  """

  @doc """
  `Decimal.round(d, 0, mode)`, except that a value already integral and
  too wide for the context precision comes back unchanged rather than
  raising.
  """
  @spec round_integral(Decimal.t(), Decimal.rounding()) :: Decimal.t()
  def round_integral(%Decimal{coef: coef, exp: exp} = d, mode)
      when is_integer(coef) and exp >= 0 do
    if length(Integer.digits(coef)) + exp > Decimal.Context.get().precision,
      do: d,
      else: Decimal.round(d, 0, mode)
  end

  def round_integral(%Decimal{} = d, mode), do: Decimal.round(d, 0, mode)
end
