defmodule TradingCore.MarketHours.UsEquitiesHolidays do
  @moduledoc """
  Static NYSE/NASDAQ (shared US equities) holiday calendar backing
  `TradingCore.MarketHours.holiday?/2` for `market: "US_EQUITIES"`.

  Hardcoded rather than computed or looked up via an API, on purpose, for
  this first pass — the exchanges publish a fixed schedule years in
  advance, and the observed-date rules below (weekend-holiday shifting)
  are simple enough that hand-verified literal dates are both simpler and
  more auditable than encoding the underlying rules (nth-weekday-of-month,
  Easter/Good Friday, observed-date shifting) in code. Extend `@holidays`
  as further years are published; there is no interface change required to
  extend the calendar.

  Does not include early-close (half) days — this only answers "is the
  market fully closed," not "is it closing early."

  Starts at 2023: `holiday?/1` answers `false` for any earlier date, so a
  backtest further back than that would treat its holidays as trading
  days. Add the earlier years first if one is needed.

  Also lists **unscheduled** full closures the exchanges announced at
  short notice (e.g. a national day of mourning), since a backtest or a
  data fetch over that date must treat it as a non-trading day too.
  """

  # New Year's Day, MLK Day, Presidents Day, Good Friday, Memorial Day,
  # Juneteenth, Independence Day, Labor Day, Thanksgiving, Christmas.
  # Observed-date rule already applied where a fixed-date holiday falls on
  # a weekend (Saturday -> observed the preceding Friday, Sunday ->
  # observed the following Monday), except that NYSE does not close the
  # Friday before a Saturday holiday when that Friday ends a month or
  # year — so a Saturday New Year's Day is simply not observed (see
  # 2028) — floating holidays (MLK, Presidents,
  # Memorial, Labor, Thanksgiving) are already always weekdays by
  # definition and never need this shift.
  @holidays MapSet.new([
              # 2023 and 2024 checked against NYSE Group's "2022, 2023 and
              # 2024 Holiday and Early Closings Calendar" release
              # (2021-12-27), 2026-10-04.
              # 2023 — New Year's Day (Sunday) observed Monday Jan 2.
              ~D[2023-01-02],
              ~D[2023-01-16],
              ~D[2023-02-20],
              ~D[2023-04-07],
              ~D[2023-05-29],
              ~D[2023-06-19],
              ~D[2023-07-04],
              ~D[2023-09-04],
              ~D[2023-11-23],
              ~D[2023-12-25],
              # 2024
              ~D[2024-01-01],
              ~D[2024-01-15],
              ~D[2024-02-19],
              ~D[2024-03-29],
              ~D[2024-05-27],
              ~D[2024-06-19],
              ~D[2024-07-04],
              ~D[2024-09-02],
              ~D[2024-11-28],
              ~D[2024-12-25],
              # 2025
              ~D[2025-01-01],
              # Unscheduled: national day of mourning for President
              # Carter (NYSE announcement, 2024-12-30).
              ~D[2025-01-09],
              ~D[2025-01-20],
              ~D[2025-02-17],
              ~D[2025-04-18],
              ~D[2025-05-26],
              ~D[2025-06-19],
              ~D[2025-07-04],
              ~D[2025-09-01],
              ~D[2025-11-27],
              ~D[2025-12-25],
              # 2026
              ~D[2026-01-01],
              ~D[2026-01-19],
              ~D[2026-02-16],
              ~D[2026-04-03],
              ~D[2026-05-25],
              ~D[2026-06-19],
              # 2026-07-04 is a Saturday -> observed Friday 2026-07-03.
              ~D[2026-07-03],
              ~D[2026-09-07],
              ~D[2026-11-26],
              ~D[2026-12-25],
              # 2027
              ~D[2027-01-01],
              ~D[2027-01-18],
              ~D[2027-02-15],
              ~D[2027-03-26],
              ~D[2027-05-31],
              # 2027-06-19 is a Saturday -> observed Friday 2027-06-18.
              ~D[2027-06-18],
              ~D[2027-07-05],
              ~D[2027-09-06],
              ~D[2027-11-25],
              # 2027-12-25 is a Saturday -> observed Friday 2027-12-24.
              ~D[2027-12-24],
              # 2028 (checked against nyse.com/markets/hours-calendars,
              # 2026-09-25). 2028-01-01 is a Saturday; NYSE observes no
              # New Year's Day holiday, so 2027-12-31 is a trading day.
              ~D[2028-01-17],
              ~D[2028-02-21],
              ~D[2028-04-14],
              ~D[2028-05-29],
              ~D[2028-06-19],
              ~D[2028-07-04],
              ~D[2028-09-04],
              ~D[2028-11-23],
              ~D[2028-12-25]
            ])

  # Last day of the last calendar year listed in @holidays.
  @covered_through @holidays |> Enum.map(& &1.year) |> Enum.max() |> Date.new!(12, 31)

  @doc """
  The last date this calendar covers: 31 December of the last year listed.
  `holiday?/1` answers `false` for any later date, so a date past this is
  unchecked rather than known not to be a holiday. A test fails when this
  gets within about 400 days of today, so the calendar is extended before
  option expiries (up to ~120 days out) reach an unchecked year.
  """
  @spec covered_through() :: Date.t()
  def covered_through, do: @covered_through

  @doc "True if `date` is a US equities (NYSE/NASDAQ) market holiday."
  @spec holiday?(Date.t()) :: boolean()
  def holiday?(%Date{} = date), do: MapSet.member?(@holidays, date)
end
