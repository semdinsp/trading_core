defmodule TradingCore.MarketHours.UsEquitiesEarlyCloses do
  @moduledoc """
  Static NYSE/NASDAQ (shared US equities) early-close calendar backing
  `TradingCore.MarketHours.early_close/2` for `market: "US_EQUITIES"`.

  The companion to `TradingCore.MarketHours.UsEquitiesHolidays`: that
  table answers "is the market fully closed," this one answers "does the
  core session end early." Same policy — hand-verified literal dates from
  the exchange's published calendar, not rules encoded in code — because
  early closes are announced, not derived (e.g. 2026 has no July 3 early
  close because July 3 is itself the observed Independence Day holiday).

  Each entry is the early close time in `America/New_York`. Every one so
  far is 13:00 ET for equities (eligible options run to 13:15; that is
  not modelled here). Extended/late sessions also shorten on these days;
  that is not modelled either — this only moves the core close.
  """

  @timezone "America/New_York"

  @early_closes %{
    # 2025 — day before Independence Day, day after Thanksgiving,
    # Christmas Eve.
    ~D[2025-07-03] => ~T[13:00:00],
    ~D[2025-11-28] => ~T[13:00:00],
    ~D[2025-12-24] => ~T[13:00:00],
    # 2026–2028 checked against nyse.com/markets/hours-calendars,
    # 2026-09-25. 2026 has no July early close (July 3 is the observed
    # holiday); 2027 has neither a July nor a Christmas Eve early close
    # (July 5 and December 24 are observed holidays).
    ~D[2026-11-27] => ~T[13:00:00],
    ~D[2026-12-24] => ~T[13:00:00],
    ~D[2027-11-26] => ~T[13:00:00],
    ~D[2028-07-03] => ~T[13:00:00],
    ~D[2028-11-24] => ~T[13:00:00]
  }

  # Explicit rather than derived from the table, because a year can
  # legitimately contain no early closes at all (2028 has no Christmas Eve
  # one, and a year with none would otherwise look "not covered").
  @covered_through ~D[2028-12-31]

  @doc """
  The last date this calendar covers. `close_time/1` answers `nil` for any
  later date, so a date past this is unchecked rather than known to be a
  full day. A test fails when this gets within about 400 days of today,
  matching `UsEquitiesHolidays.covered_through/0`.
  """
  @spec covered_through() :: Date.t()
  def covered_through, do: @covered_through

  @doc "The IANA timezone `close_time/1`'s times are expressed in."
  @spec timezone() :: String.t()
  def timezone, do: @timezone

  @doc """
  The early close time on `date` (in `timezone/0`), or `nil` if `date` is
  not an early-close day.
  """
  @spec close_time(Date.t()) :: Time.t() | nil
  def close_time(%Date{} = date), do: Map.get(@early_closes, date)
end
