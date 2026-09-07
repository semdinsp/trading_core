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
  """

  # New Year's Day, MLK Day, Presidents Day, Good Friday, Memorial Day,
  # Juneteenth, Independence Day, Labor Day, Thanksgiving, Christmas.
  # Observed-date rule already applied where a fixed-date holiday falls on
  # a weekend (Saturday -> observed the preceding Friday, Sunday ->
  # observed the following Monday) — floating holidays (MLK, Presidents,
  # Memorial, Labor, Thanksgiving) are already always weekdays by
  # definition and never need this shift.
  @holidays MapSet.new([
              # 2025
              ~D[2025-01-01],
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
              ~D[2027-12-24]
            ])

  @doc "True if `date` is a US equities (NYSE/NASDAQ) market holiday."
  @spec holiday?(Date.t()) :: boolean()
  def holiday?(%Date{} = date), do: MapSet.member?(@holidays, date)
end
