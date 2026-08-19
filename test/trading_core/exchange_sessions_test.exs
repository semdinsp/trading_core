defmodule TradingCore.ExchangeSessionsTest do
  use ExUnit.Case, async: true

  alias TradingCore.ExchangeSessions

  @mapping %{
    "NYSE" => "US",
    "NASDAQ" => "US",
    "SMART" => "US",
    "ARCA" => "US",
    "SGX" => "Asia",
    "SEHK" => "Asia"
  }

  test "resolves a mapped exchange to its session name" do
    assert ExchangeSessions.session_name("NYSE", @mapping) == "US"
    assert ExchangeSessions.session_name("SEHK", @mapping) == "Asia"
  end

  test "returns nil for an unmapped exchange" do
    assert ExchangeSessions.session_name("TSX", @mapping) == nil
  end

  test "returns nil for a nil exchange" do
    assert ExchangeSessions.session_name(nil, @mapping) == nil
  end
end
