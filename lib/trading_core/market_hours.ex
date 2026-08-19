defmodule TradingCore.MarketHours do
  @moduledoc """
  Time-math for a named market session window (e.g. "US", "Asia") —
  `timezone` (IANA name) plus a local `start_time`/`end_time`, and which
  days of the week the session actually trades (`days_of_week`).

  Extracted from `TradingSystem.Trading.MarketHour` into this shared
  library so `trading_system` and `trading_live` share the exact same
  time-math (IANA timezone handling, DST, weekend/holiday edge cases) even
  though each app owns its own session *data* independently (`trading_system`
  in its `market_hours` table, `trading_live` in its own local, editable
  `exchange_trading_hours` settings table). This module takes a plain
  `%TradingCore.MarketHours.Session{}` struct — not an Ecto schema — so
  neither caller needs to depend on the other's persistence layer; each
  builds a `Session` from whatever its own storage returns.

  This logic has already absorbed several real production incidents (see
  each function's doc) — preserve the exact behavior described there when
  changing anything here; a regression reintroduces a bug that has already
  caused live incidents once.
  """

  alias TradingCore.MarketHours.Session

  @doc """
  The next UTC instant `session`'s session closes at or after `now`, i.e.
  the closing bell for today's session if `now` falls before it (even
  before that session's own open), or tomorrow's if `now` is already past
  today's close. Ignores whether `now` falls on a weekend/holiday or
  outside `start_time` — this backs a *cap* on an already-computed
  deadline, not an "is the market open right now" check, so it's fine for
  the returned instant to be a close time on a day the market never
  actually opened; the caller only ever uses this as an upper bound, not a
  standalone gate. Returns `nil` if `session.enabled` is `false`.
  """
  @spec next_close(Session.t(), DateTime.t()) :: DateTime.t() | nil
  def next_close(%Session{enabled: false}, _now), do: nil

  def next_close(%Session{} = session, %DateTime{} = now) do
    {:ok, local_now} = DateTime.shift_zone(now, session.timezone)
    today = DateTime.to_date(local_now)

    {:ok, close_today} = DateTime.new(today, session.end_time, session.timezone)

    close_today =
      if DateTime.compare(local_now, close_today) == :gt do
        {:ok, close_tomorrow} =
          DateTime.new(Date.add(today, 1), session.end_time, session.timezone)

        close_tomorrow
      else
        close_today
      end

    DateTime.shift_zone!(close_today, "Etc/UTC")
  end

  @doc """
  The UTC instant `session`'s session opened on `now`'s local calendar day
  (in `session.timezone`) — unlike `next_close/2`, this always answers for
  *the same day `now` falls on*, never rolling forward to a future day,
  since callers use this to measure how much of *that day's* session had
  already elapsed by `now`, not to find some future open. Ignores
  weekends/holidays, same blind spot as `next_close/2` and `open?/2` — it's
  fine for this to return an instant on a day the market never actually
  opened, since the caller only uses it as a reference point for
  elapsed-time math, not as a standalone "is the market open" gate. Returns
  `nil` if `session.enabled` is `false`.
  """
  @spec today_open(Session.t(), DateTime.t()) :: DateTime.t() | nil
  def today_open(%Session{enabled: false}, _now), do: nil

  def today_open(%Session{} = session, %DateTime{} = now) do
    {:ok, local_now} = DateTime.shift_zone(now, session.timezone)
    today = DateTime.to_date(local_now)

    {:ok, open_today} = DateTime.new(today, session.start_time, session.timezone)

    DateTime.shift_zone!(open_today, "Etc/UTC")
  end

  @doc """
  `true` if `session` is currently within its local `start_time`/`end_time`
  window at `now`, on a day `days_of_week` marks as a trading day — a
  genuine "is the market open right now" check, unlike `next_close/2` which
  always returns a future instant regardless of whether `now` falls inside
  or outside the session.

  **Real-incident fix (originally 2026-08-15, `trading_system`)**: this used
  to only compare the local clock against `start_time`/`end_time`, with no
  day-of-week check at all. A Saturday's local ET clock fell inside a
  seeded "US" row's 09:30-16:00 window exactly as it would on a weekday, so
  this returned `true` all day, causing hundreds of `StrategyRun`s to open
  on a non-trading day. Now gated on `Date.day_of_week/1` (1 = Monday ..
  7 = Sunday, same convention `days_of_week` itself stores) against
  `local_now`'s own calendar day — computed in `session.timezone`, same as
  the time-of-day comparison below, so a session that crosses local
  midnight relative to UTC still resolves against the *session's* day, not
  UTC's. Returns `false` (i.e. "not open," so callers already treat it as
  time-to-deactivate) if `session.enabled` is `false`.
  """
  @spec open?(Session.t(), DateTime.t()) :: boolean()
  def open?(%Session{enabled: false}, _now), do: false

  def open?(%Session{} = session, %DateTime{} = now) do
    {:ok, local_now} = DateTime.shift_zone(now, session.timezone)
    local_time = DateTime.to_time(local_now)

    trading_day?(session, local_now) and
      Time.compare(local_time, session.start_time) != :lt and
      Time.compare(local_time, session.end_time) == :lt
  end

  @doc """
  `true` if `session`'s session has already ended for the day at `now` —
  i.e. the local clock is at or past `end_time`. Unlike `open?/2`, this
  does NOT also return `true` before the session has opened yet (local
  clock before `start_time`) — that's "hasn't started today," not "closed
  for the day," and the two must not be conflated.

  Added as a real-incident fix (`trading_system`): a caller previously used
  `not open?/2` to decide "closed for the day," which is true in both the
  pre-open and post-close cases (`open?/2` only ever answers "is it open
  right now"). A version deployed pre-market got deactivated within one
  10-minute cron tick of being created, before its session had even
  opened, and the day's entire batch closed with zero runs as a direct
  result. Use this function, not `not open?/2`, anywhere "has today's
  session ended" is the actual question — `open?/2` itself is correct for
  what it already claims to answer and needs no change.

  **Real-incident fix (originally 2026-08-15)**: this used to only compare
  the local clock against `end_time`, with no day-of-week check — see
  `open?/2`'s own doc for the incident this was part of. On a non-trading
  day (per `days_of_week`), this now returns `true` regardless of clock
  time — deliberately different from `open?/2`'s non-trading-day answer of
  `false`. The two functions answer different questions: `open?/2` asks "is
  a fresh entry allowed right now" (a non-trading day is never a yes),
  while `closed_for_today?/2` asks "should an *already-open* position be
  force-closed" (a non-trading day is never a reason to leave one open
  indefinitely — force-close it exactly as if the session had already
  ended, which for every practical purpose it has). Returns `false` (i.e.
  "not yet closed, so don't deactivate on this basis") if `session.enabled`
  is `false` — a disabled session was never open in the first place, so
  "closed" isn't the right read either; a caller requiring *every* relevant
  session to resolve `true` before deactivating should already fail-closed
  correctly on a disabled/unmapped session via that structure.

  **Real-incident fix (originally 2026-08-18)**: "today" here used to be
  `now`'s calendar date *in `session.timezone`*, computed independently per
  call — correct for a single session judged in isolation, but wrong the
  moment a caller compares two sessions in different timezones whose local
  calendar days are out of sync at the same UTC instant. Confirmed live: at
  US close (16:00 ET = 20:00 UTC), Tokyo local time is already the next
  calendar day, hours before that day's own 09:00 Asia open — so this
  function, asked about "Asia today," was evaluating a session that
  genuinely hadn't happened *yet on Tokyo's new day* and correctly-by-its-
  own-logic returned `false`. Versions spanning both sessions stayed
  active for hours after US close as a direct result.

  Fixed by anchoring "today" to **`now`'s own UTC calendar date**, shared
  across every session being asked about, instead of letting each session
  independently re-derive its own local "today" via `DateTime.shift_zone/2`.
  Every session's scheduled open/close instant for that *same*
  UTC-referenced day is computed directly in `session.timezone` — this
  still correctly answers "is it currently before this session's own open"
  (the earlier fix above, still intact) since a session's own open/close
  times relative to a *fixed* calendar day behave identically to the old
  per-session-day computation in every single-session case — the two
  approaches only ever diverge when comparing sessions whose local calendar
  days have drifted apart at the same shared instant, which is exactly the
  bug being fixed.

  **One deliberate behavior nuance at a boundary rarely exercised**: late
  Sunday evening in `session.timezone` (e.g. ET, ~23:00-23:59) where the
  UTC calendar has already rolled to Monday. Old local-day logic saw
  "Sunday" (a non-trading day) and answered `true` (closed) regardless of
  clock time. This version sees UTC-Monday (a real trading day) and
  correctly answers `false` until Monday's own local close has passed —
  Monday's session genuinely hasn't opened yet at that instant, and
  answering `true` there would wrongly treat an about-to-open Monday
  session as already finished for the day. Ordinary Saturday/Sunday
  daytime hours are unaffected — only the last ~1 hour of Sunday night (in
  this timezone) before the UTC date changes underneath it.
  """
  @spec closed_for_today?(Session.t(), DateTime.t()) :: boolean()
  def closed_for_today?(%Session{enabled: false}, _now), do: false

  def closed_for_today?(%Session{} = session, %DateTime{} = now) do
    # Anchored to `now`'s UTC calendar date specifically — not `now`'s own
    # zone, whatever that happens to be — so this reference date is the
    # same regardless of which zone a caller's `now` argument carries. If
    # this instead used `DateTime.to_date(now)` directly, the same instant
    # could resolve to two different reference dates depending on `now`'s
    # zone (e.g. 23:30 ET vs. the same instant's 03:30 UTC the next day),
    # silently reintroducing the exact cross-timezone ambiguity this whole
    # fix exists to eliminate. Every caller should pass `DateTime.utc_now()`
    # so this shift is a no-op there — it exists to make the function
    # correct by construction rather than correct-by-caller-convention.
    {:ok, now_utc} = DateTime.shift_zone(now, "Etc/UTC")
    reference_date = DateTime.to_date(now_utc)

    {:ok, close_today} = DateTime.new(reference_date, session.end_time, session.timezone)
    close_today_utc = DateTime.shift_zone!(close_today, "Etc/UTC")

    weekday = Date.day_of_week(reference_date)

    weekday not in session.days_of_week or
      DateTime.compare(now, close_today_utc) != :lt
  end

  @doc """
  `true` if `now`'s calendar day, in `session.timezone`, is one of
  `session.days_of_week` — deliberately independent of `enabled` (unlike
  `open?/2`/`closed_for_today?/2`, both of which short-circuit to a fixed
  answer when disabled). Useful for an "is this row unexpectedly disabled
  during its own trading week" health check, which specifically needs
  "would this normally be a trading day for this row" as a question
  independent of the row's current `enabled` value, since `enabled: false`
  is exactly the state being flagged as suspicious.
  """
  @spec today_is_a_trading_day?(Session.t(), DateTime.t()) :: boolean()
  def today_is_a_trading_day?(%Session{} = session, %DateTime{} = now) do
    {:ok, local_now} = DateTime.shift_zone(now, session.timezone)
    trading_day?(session, local_now)
  end

  # `local_now`'s calendar day, in `session.timezone`, is one of
  # `session.days_of_week` — the actual day-of-week gate `open?/2`,
  # `closed_for_today?/2`, and `today_is_a_trading_day?/2` are all built
  # on. Takes an already-shifted `DateTime` (not `now` in its original
  # zone) since every caller already has `local_now` on hand from its own
  # `DateTime.shift_zone/2` call and shifting twice would be redundant.
  defp trading_day?(%Session{days_of_week: days_of_week}, %DateTime{} = local_now) do
    weekday = local_now |> DateTime.to_date() |> Date.day_of_week()
    weekday in days_of_week
  end
end
