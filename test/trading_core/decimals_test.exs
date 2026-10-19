defmodule TradingCore.DecimalsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias TradingCore.Decimals

  defp raises?(d, places, mode) do
    Decimal.round(d, places, mode)
    false
  rescue
    Decimal.Error -> true
  end

  test "a value too wide for the context precision comes back unchanged, not raising" do
    huge = Decimal.new("7.307508186654515E+47")
    assert raises?(huge, 0, :floor)
    assert Decimals.round(huge, 0, :floor) == huge
    assert Decimals.round(Decimal.negate(huge), 8) == Decimal.negate(huge)
  end

  test "the boundary follows the context precision and the places" do
    p = Decimal.Context.get().precision

    for places <- [0, 2, 8] do
      at_limit = Decimal.new(1, 1, p - places - 1)
      too_wide = Decimal.new(1, 1, p - places)

      assert Decimals.round(at_limit, places) == Decimal.round(at_limit, places)
      assert raises?(too_wide, places, :half_up)
      assert Decimals.round(too_wide, places) == too_wide
    end
  end

  test "ordinary values round exactly as Decimal.round/3" do
    for {v, places, mode} <- [
          {"2.5", 0, :half_up},
          {"2.5", 0, :floor},
          {"-2.1", 0, :ceiling},
          {"1E+3", 0, :floor},
          {"1.234567891", 8, :half_up},
          {"19.995", 2, :half_even},
          {"0", 2, :up}
        ] do
      d = Decimal.new(v)
      assert Decimals.round(d, places, mode) == Decimal.round(d, places, mode)
    end
  end

  property "agrees with Decimal.round/3 wherever that doesn't raise, and never raises on a finite value" do
    check all(
            coef <- integer((-10 ** 36)..(10 ** 36)),
            exp <- integer(-12..40),
            places <- integer(-2..10),
            mode <- member_of([:floor, :ceiling, :up, :down, :half_up, :half_even])
          ) do
      d = Decimal.new(if(coef < 0, do: -1, else: 1), abs(coef), exp)

      if raises?(d, places, mode) do
        # only an operand from outside Decimal arithmetic (a coefficient
        # wider than the precision) can still raise with fraction digits
        if exp >= -places,
          do: assert(Decimals.round(d, places, mode) == d),
          else: assert(length(Integer.digits(abs(coef))) > Decimal.Context.get().precision)
      else
        assert Decimals.round(d, places, mode) == Decimal.round(d, places, mode)
      end
    end
  end
end
