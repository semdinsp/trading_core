defmodule TradingCore.MarketHours.Session do
  @moduledoc """
  Plain struct mirroring `trading_system`'s `MarketHour` Ecto schema shape
  (`name`, `timezone`, `start_time`, `end_time`, `enabled`, `days_of_week`)
  — deliberately not an Ecto schema itself, so `trading_core` has no
  dependency on Ecto/a database. Each caller (`trading_system`'s
  `market_hours` table, `trading_live`'s own `exchange_trading_hours`
  table) builds one of these from its own storage before calling
  `TradingCore.MarketHours` functions.
  """

  @enforce_keys [:name, :timezone, :start_time, :end_time]
  defstruct name: nil,
            timezone: nil,
            start_time: nil,
            end_time: nil,
            enabled: true,
            days_of_week: [1, 2, 3, 4, 5]

  @type t :: %__MODULE__{
          name: String.t(),
          timezone: String.t(),
          start_time: Time.t(),
          end_time: Time.t(),
          enabled: boolean(),
          days_of_week: [1..7]
        }
end
