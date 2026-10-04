defmodule TradingCore.Intraday.RegularSessionTest do
  use ExUnit.Case, async: true

  alias TradingCore.Intraday.RegularSession

  describe "bounds/1" do
    test "no session on a scheduled holiday or an unscheduled closure" do
      # New Year's Day 2024; the national day of mourning for President Carter.
      assert RegularSession.bounds(~D[2024-01-01]) == :error
      assert RegularSession.bounds(~D[2025-01-09]) == :error
    end

    test "the days around them are normal sessions" do
      assert {:ok, open, close} = RegularSession.bounds(~D[2025-01-10])
      assert open == ~U[2025-01-10 14:30:00Z]
      assert close == ~U[2025-01-10 21:00:00Z]
    end

    test "a 2024 early close ends at 13:00 ET" do
      assert {:ok, _open, close} = RegularSession.bounds(~D[2024-12-24])
      assert close == ~U[2024-12-24 18:00:00Z]
    end
  end
end
