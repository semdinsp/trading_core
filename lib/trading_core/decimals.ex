defmodule TradingCore.Decimals do
  @moduledoc """
  Decimal helpers shared across trading_core.

  ## Rounding without raising (decimal >= 3.2.0)

  From 3.2.0 (the fix for EEF-CVE-2026-97853), `Decimal.round/3` raises
  `Decimal.Error` (`invalid_operation`) when the result has more digits
  than the context precision (34 by default). Rounding to `places`
  therefore raises once a value reaches about `10^(34 - places)`: 1e34
  for whole numbers, 1e26 at 8 places. 3.1.1 returned the wide result.

  `round/3` returns such a value unchanged instead. It only raises when
  the value's exponent is already at or above `-places`, i.e. it has no
  digits past the rounding point, so rounding could not change it and
  returning it as is is exact. Every other input rounds exactly as
  `Decimal.round/3` does, so results are unchanged wherever 3.1.1 didn't
  raise. Every rounding in trading_core goes through it, so a garbage
  input flows through as a (huge) number rather than crashing a caller
  such as trading_live's guardian.
  """

  @doc """
  `Decimal.round(d, places, mode)`, except that a value with no digits
  past `places` that is too wide for the context precision comes back
  unchanged rather than raising.
  """
  @spec round(Decimal.t(), integer(), Decimal.rounding()) :: Decimal.t()
  def round(d, places, mode \\ :half_up)

  def round(%Decimal{coef: coef, exp: exp} = d, places, mode)
      when is_integer(coef) and exp >= -places do
    if length(Integer.digits(coef)) + exp + places > Decimal.Context.get().precision,
      do: d,
      else: Decimal.round(d, places, mode)
  end

  def round(%Decimal{} = d, places, mode), do: Decimal.round(d, places, mode)
end
