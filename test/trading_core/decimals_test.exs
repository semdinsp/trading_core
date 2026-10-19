defmodule TradingCore.DecimalsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias TradingCore.Decimals

  test "a value too wide for the context precision comes back unchanged, not raising" do
    huge = Decimal.new("7.307508186654515E+47")
    assert Decimals.round_integral(huge, :floor) == huge
    assert Decimals.round_integral(Decimal.negate(huge), :ceiling) == Decimal.negate(huge)

    # exactly at the context precision rounds normally; one digit wider is returned as is
    p = Decimal.Context.get().precision
    at_limit = Decimal.new(1, 1, p - 1)
    too_wide = Decimal.new(1, 1, p)
    assert Decimals.round_integral(at_limit, :up) == Decimal.round(at_limit, 0, :up)
    assert_raise Decimal.Error, fn -> Decimal.round(too_wide, 0, :up) end
    assert Decimals.round_integral(too_wide, :up) == too_wide
  end

  test "ordinary values round exactly as Decimal.round/3 to 0 places" do
    for {v, mode} <- [
          {"2.5", :half_up},
          {"2.5", :floor},
          {"2.1", :up},
          {"-2.1", :ceiling},
          {"1E+3", :floor},
          {"0", :up}
        ] do
      d = Decimal.new(v)
      assert Decimals.round_integral(d, mode) == Decimal.round(d, 0, mode)
    end
  end

  property "agrees with Decimal.round/3 whenever that doesn't raise" do
    check all(
            coef <- integer((-10 ** 36)..(10 ** 36)),
            exp <- integer(-12..40),
            mode <- member_of([:floor, :ceiling, :up, :down, :half_up, :half_even])
          ) do
      d = Decimal.new(if(coef < 0, do: -1, else: 1), abs(coef), exp)

      case (try do
              {:ok, Decimal.round(d, 0, mode)}
            rescue
              Decimal.Error -> :raised
            end) do
        {:ok, expected} -> assert Decimals.round_integral(d, mode) == expected
        :raised when exp >= 0 -> assert Decimals.round_integral(d, mode) == d
        :raised -> :ok
      end
    end
  end
end
