defmodule TradingCore.Options.OccTest do
  use ExUnit.Case, async: true

  alias TradingCore.Options.Occ

  test "a call" do
    assert {:ok, parsed} = Occ.parse("SPY261001C00550000")
    assert parsed.root == "SPY"
    assert parsed.expiry == ~D[2026-10-01]
    assert parsed.right == :call
    assert Decimal.equal?(parsed.strike, Decimal.new("550.000"))
  end

  test "a put" do
    assert {:ok, %{root: "QQQ", right: :put, expiry: ~D[2026-11-20]} = parsed} =
             Occ.parse("QQQ261120P00715000")

    assert Decimal.equal?(parsed.strike, 715)
  end

  test "SPX weeklies keep the SPXW root" do
    assert {:ok, %{root: "SPXW", right: :call} = parsed} = Occ.parse("SPXW261001C07650000")
    assert Decimal.equal?(parsed.strike, 7650)
  end

  test "fractional strikes" do
    assert {:ok, parsed} = Occ.parse("SPY261001C00552500")
    assert Decimal.equal?(parsed.strike, Decimal.new("552.5"))

    assert {:ok, parsed} = Occ.parse("XLF261120P00053500")
    assert Decimal.equal?(parsed.strike, Decimal.new("53.5"))
  end

  test "one-character, digit-bearing and space-padded roots" do
    assert {:ok, %{root: "F"}} = Occ.parse("F261120C00012000")
    assert {:ok, %{root: "SPY1"}} = Occ.parse("SPY1261120C00550000")
    assert {:ok, %{root: "SPY"}} = Occ.parse("SPY   261001C00550000")
  end

  test "anything malformed is :error, never a raise" do
    for bad <- [
          "",
          "SPY",
          "261001C00550000",
          "SPY261001X00550000",
          "SPY261301C00550000",
          "SPY260230C00550000",
          "SPY261001C0055000",
          "SPY261001C005500000",
          "spy261001C00550000",
          "TOOLONG261001C00550000",
          "SP-261001C00550000",
          nil,
          :spy,
          550
        ] do
      assert Occ.parse(bad) == :error, "expected :error for #{inspect(bad)}"
    end
  end
end
