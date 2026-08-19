defmodule TradingCore.ExchangeSessions do
  @moduledoc """
  Lookup helper for mapping an `Instrument.exchange` string (e.g. `"NYSE"`,
  `"SEHK"`) to the `TradingCore.MarketHours.Session` name it trades under
  (e.g. `"US"`, `"Asia"`).

  Deliberately takes the exchange→session map as an argument rather than
  hardcoding one, unlike `trading_system`'s original
  `TradingSystem.Trading.ExchangeSession` (a fixed module attribute) —
  `trading_system` keeps owning its own static map, while `trading_live`
  owns an editable `exchange_sessions` settings table so an operator can
  correct exchange mappings (e.g. adding a genuine Hong Kong session)
  without a code deploy. Both call this same lookup function against their
  own map.
  """

  @doc "The session name `exchange` trades under, per `mapping`, or `nil` if unmapped."
  @spec session_name(String.t() | nil, %{optional(String.t()) => String.t()}) ::
          String.t() | nil
  def session_name(exchange, mapping) when is_map(mapping), do: Map.get(mapping, exchange)
end
