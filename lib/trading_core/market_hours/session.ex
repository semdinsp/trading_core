defmodule TradingCore.MarketHours.Session do
  @moduledoc """
  Plain struct mirroring `trading_system`'s `MarketHour` Ecto schema shape
  (`name`, `timezone`, `start_time`, `end_time`, `enabled`, `days_of_week`)
  — deliberately not an Ecto schema itself, so `trading_core` has no
  dependency on Ecto/a database. Each caller (`trading_system`'s
  `market_hours` table, `trading_live`'s own `exchange_trading_hours`
  table) builds one of these from its own storage before calling
  `TradingCore.MarketHours` functions.

  `market` is a stable identifier `TradingCore.MarketHours.holiday?/2` keys
  its static calendar off — deliberately separate from `name`, which is
  free-text, operator-editable display text (e.g. "US" or
  "NASDAQ-monitor-test" in tests) not safe to key a holiday calendar off.
  Defaults to `"US_EQUITIES"` since every session in both `trading_system`
  and `trading_live` today genuinely is US equities.

  `extra_holidays` is each caller's own ad-hoc, manually-declared one-off
  closure dates (e.g. an operator toggling a special/unscheduled closure on
  in their own app's settings UI) — a plain `Date.t()` list/set the caller
  builds from its *own* storage, ORed with `market`'s static calendar by
  every trading-day check in this module. `trading_core` has no concept of
  where these come from or how they're persisted; each app owns that
  entirely (its own table, its own UI) and just passes the resulting dates
  in here. Defaults to `[]`.
  """

  @enforce_keys [:name, :timezone, :start_time, :end_time]
  defstruct name: nil,
            timezone: nil,
            start_time: nil,
            end_time: nil,
            enabled: true,
            days_of_week: [1, 2, 3, 4, 5],
            market: "US_EQUITIES",
            extra_holidays: []

  @type t :: %__MODULE__{
          name: String.t(),
          timezone: String.t(),
          start_time: Time.t(),
          end_time: Time.t(),
          enabled: boolean(),
          days_of_week: [1..7],
          market: String.t(),
          extra_holidays: [Date.t()]
        }
end
