defmodule TradingCore.MarketHoursTest do
  use ExUnit.Case, async: true

  alias TradingCore.MarketHours
  alias TradingCore.MarketHours.Session

  @us %Session{
    name: "US",
    timezone: "America/New_York",
    start_time: ~T[09:30:00],
    end_time: ~T[16:00:00],
    enabled: true
  }

  describe "next_close/2" do
    test "returns today's close when now is before it" do
      # 2026-07-20 is a Monday.
      now = DateTime.new!(~D[2026-07-20], ~T[11:00:00], "America/New_York")

      close = MarketHours.next_close(@us, now)

      assert DateTime.to_date(DateTime.shift_zone!(close, "America/New_York")) == ~D[2026-07-20]
      assert DateTime.shift_zone!(close, "America/New_York") |> DateTime.to_time() == ~T[16:00:00]
    end

    test "returns today's close when now is exactly at close" do
      now = DateTime.new!(~D[2026-07-20], ~T[16:00:00], "America/New_York")

      close = MarketHours.next_close(@us, now)

      assert DateTime.to_date(DateTime.shift_zone!(close, "America/New_York")) == ~D[2026-07-20]
    end

    test "rolls to tomorrow's close when now is already past today's close" do
      now = DateTime.new!(~D[2026-07-20], ~T[17:00:00], "America/New_York")

      close = MarketHours.next_close(@us, now)

      assert DateTime.to_date(DateTime.shift_zone!(close, "America/New_York")) == ~D[2026-07-21]
    end

    test "returns a UTC datetime" do
      now = DateTime.new!(~D[2026-07-20], ~T[11:00:00], "America/New_York")

      close = MarketHours.next_close(@us, now)

      assert close.time_zone == "Etc/UTC"
    end

    test "returns nil when the session is disabled" do
      disabled = %{@us | enabled: false}
      now = DateTime.new!(~D[2026-07-20], ~T[11:00:00], "America/New_York")

      assert MarketHours.next_close(disabled, now) == nil
    end
  end

  describe "today_open/2" do
    test "returns the same local calendar day's open when now is during the session" do
      now = DateTime.new!(~D[2026-07-20], ~T[11:00:00], "America/New_York")

      open = MarketHours.today_open(@us, now)

      assert DateTime.to_date(DateTime.shift_zone!(open, "America/New_York")) == ~D[2026-07-20]
      assert DateTime.shift_zone!(open, "America/New_York") |> DateTime.to_time() == ~T[09:30:00]
    end

    test "still returns the same day's open when now is after that day's close (never rolls forward)" do
      now = DateTime.new!(~D[2026-07-20], ~T[17:00:00], "America/New_York")

      open = MarketHours.today_open(@us, now)

      assert DateTime.to_date(DateTime.shift_zone!(open, "America/New_York")) == ~D[2026-07-20]
    end

    test "still returns the same day's open when now is before that day's open" do
      now = DateTime.new!(~D[2026-07-20], ~T[06:00:00], "America/New_York")

      open = MarketHours.today_open(@us, now)

      assert DateTime.to_date(DateTime.shift_zone!(open, "America/New_York")) == ~D[2026-07-20]
      assert DateTime.shift_zone!(open, "America/New_York") |> DateTime.to_time() == ~T[09:30:00]
    end

    test "returns a UTC datetime" do
      now = DateTime.new!(~D[2026-07-20], ~T[11:00:00], "America/New_York")

      open = MarketHours.today_open(@us, now)

      assert open.time_zone == "Etc/UTC"
    end

    test "returns nil when the session is disabled" do
      disabled = %{@us | enabled: false}
      now = DateTime.new!(~D[2026-07-20], ~T[11:00:00], "America/New_York")

      assert MarketHours.today_open(disabled, now) == nil
    end
  end

  describe "open?/2" do
    test "true during the session" do
      now = DateTime.new!(~D[2026-07-20], ~T[11:00:00], "America/New_York")
      assert MarketHours.open?(@us, now)
    end

    test "true exactly at start_time" do
      now = DateTime.new!(~D[2026-07-20], ~T[09:30:00], "America/New_York")
      assert MarketHours.open?(@us, now)
    end

    test "false exactly at end_time (half-open interval)" do
      now = DateTime.new!(~D[2026-07-20], ~T[16:00:00], "America/New_York")
      refute MarketHours.open?(@us, now)
    end

    test "false before the session starts" do
      now = DateTime.new!(~D[2026-07-20], ~T[08:00:00], "America/New_York")
      refute MarketHours.open?(@us, now)
    end

    test "false after the session closes" do
      now = DateTime.new!(~D[2026-07-20], ~T[17:00:00], "America/New_York")
      refute MarketHours.open?(@us, now)
    end

    test "converts now into the session's own timezone before comparing" do
      # 17:00 UTC is 13:00 ET (during DST) -- open in US session terms even
      # though the raw UTC clock time (17:00) would read as after a naive
      # 16:00 end_time if compared without shifting timezone first.
      now = DateTime.new!(~D[2026-07-20], ~T[17:00:00], "Etc/UTC")
      assert MarketHours.open?(@us, now)
    end

    test "false when the session is disabled, even during what would be session hours" do
      disabled = %{@us | enabled: false}
      now = DateTime.new!(~D[2026-07-20], ~T[11:00:00], "America/New_York")

      refute MarketHours.open?(disabled, now)
    end

    # Real-incident regression (2026-08-15, trading_system): open?/2 used to
    # only compare clock time against start_time/end_time, with no
    # day-of-week check at all -- so a Saturday afternoon inside the normal
    # 09:30-16:00 window read as "open" exactly like a weekday. 2026-08-15
    # was a Saturday; this test uses that exact date to pin the incident.
    test "false on a Saturday during what would be session hours (2026-08-15 incident)" do
      now = DateTime.new!(~D[2026-08-15], ~T[11:00:00], "America/New_York")
      refute MarketHours.open?(@us, now)
    end

    test "false on a Sunday during what would be session hours" do
      now = DateTime.new!(~D[2026-08-16], ~T[11:00:00], "America/New_York")
      refute MarketHours.open?(@us, now)
    end

    test "true on a weekday explicitly included in days_of_week" do
      now = DateTime.new!(~D[2026-07-20], ~T[11:00:00], "America/New_York")
      assert MarketHours.open?(@us, now)
    end

    test "false on a day excluded from a narrower days_of_week" do
      monday_only = %{@us | days_of_week: [1]}
      # 2026-07-21 is a Tuesday.
      now = DateTime.new!(~D[2026-07-21], ~T[11:00:00], "America/New_York")

      refute MarketHours.open?(monday_only, now)
    end

    test "day-of-week check uses the session's own timezone, not now's original zone" do
      # 2026-08-15 (Saturday) 23:30 ET is already 2026-08-16 (Sunday) 03:30
      # UTC -- if the day check used now's original UTC date instead of
      # shifting into the session's timezone first, this would incorrectly
      # read as Sunday's date being checked against a Sunday-inclusive
      # days_of_week, when the session's own local day is still Saturday.
      saturday_and_sunday = %{
        @us
        | days_of_week: [6, 7],
          start_time: ~T[22:00:00],
          end_time: ~T[23:59:59]
      }

      now = DateTime.new!(~D[2026-08-15], ~T[23:30:00], "America/New_York")

      assert MarketHours.open?(saturday_and_sunday, now)
    end
  end

  describe "closed_for_today?/2" do
    # Real-incident regression (2026-08-06, trading_system): a caller used
    # to call `not open?/2` to mean "closed for the day," which is also
    # true before the session has opened yet -- `open?/2` only ever answers
    # "is it open right now," it can't distinguish the two. closed_for_today?/2
    # exists specifically so "hasn't opened yet" and "already closed" are
    # never conflated again.
    test "false before the session opens (this is the incident this function fixes)" do
      now = DateTime.new!(~D[2026-08-06], ~T[08:30:00], "America/New_York")
      refute MarketHours.closed_for_today?(@us, now)
    end

    test "false during the session" do
      now = DateTime.new!(~D[2026-07-20], ~T[11:00:00], "America/New_York")
      refute MarketHours.closed_for_today?(@us, now)
    end

    test "false exactly at start_time" do
      now = DateTime.new!(~D[2026-07-20], ~T[09:30:00], "America/New_York")
      refute MarketHours.closed_for_today?(@us, now)
    end

    test "true exactly at end_time" do
      now = DateTime.new!(~D[2026-07-20], ~T[16:00:00], "America/New_York")
      assert MarketHours.closed_for_today?(@us, now)
    end

    test "true after the session closes" do
      now = DateTime.new!(~D[2026-07-20], ~T[17:00:00], "America/New_York")
      assert MarketHours.closed_for_today?(@us, now)
    end

    test "converts now into the session's own timezone before comparing" do
      # Same DST-correctness case as open?/2's own test above.
      now = DateTime.new!(~D[2026-07-20], ~T[17:00:00], "Etc/UTC")
      refute MarketHours.closed_for_today?(@us, now)
    end

    test "false when the session is disabled, even well past what would be end_time" do
      # A disabled session was never open in the first place, so "closed"
      # isn't the right read either -- matches open?/2's own disabled-is-false
      # posture, not a fail-open bypass.
      disabled = %{@us | enabled: false}
      now = DateTime.new!(~D[2026-07-20], ~T[20:00:00], "America/New_York")

      refute MarketHours.closed_for_today?(disabled, now)
    end

    # Real-incident regression (2026-08-15) -- see open?/2's own tests
    # above for the incident. closed_for_today?/2 deliberately answers
    # `true` on a non-trading day regardless of clock time (unlike
    # open?/2's `false`) -- it backs force-closing an already-open
    # position, and a weekend is never a reason to leave one open.
    test "true on a Saturday even during what would be session hours" do
      now = DateTime.new!(~D[2026-08-15], ~T[11:00:00], "America/New_York")
      assert MarketHours.closed_for_today?(@us, now)
    end

    test "true on a Sunday even before what would be the session's start_time" do
      now = DateTime.new!(~D[2026-08-16], ~T[06:00:00], "America/New_York")
      assert MarketHours.closed_for_today?(@us, now)
    end

    # Real-incident regression (2026-08-18, trading_system): "today" used
    # to be `now`'s calendar date in the session's own timezone, re-derived
    # independently per call. Two versions spanning both US and Asia
    # sessions stayed active for hours after US close because Asia's own
    # local calendar day had already rolled forward to a fresh,
    # not-yet-opened trading day at that same UTC instant -- this asked "is
    # Asia closed for ITS brand-new day" and correctly-by-its-own-logic got
    # "no," even though the Asia session relevant to this UTC instant (the
    # one from many hours earlier) had long since closed. Fixed by
    # anchoring "today" to `now`'s UTC calendar date, shared across every
    # session, rather than each session's own independently-shifted local
    # date.
    @asia %Session{
      name: "Asia",
      timezone: "Asia/Tokyo",
      start_time: ~T[09:00:00],
      end_time: ~T[15:00:00],
      enabled: true
    }

    test "true for a session whose local calendar day has already rolled past the shared UTC reference day, once its own most recent session has closed (2026-08-18 cross-region incident)" do
      # US close: 2026-08-18 16:00 ET = 20:00 UTC. At that instant, Tokyo
      # local time is already 2026-08-19 05:00 -- a new Tokyo calendar
      # day, hours before that day's own 09:00 JST open.
      us_close_utc = DateTime.new!(~D[2026-08-18], ~T[20:00:00], "Etc/UTC")

      assert MarketHours.closed_for_today?(@us, us_close_utc)
      assert MarketHours.closed_for_today?(@asia, us_close_utc)
    end

    test "false for a session that hasn't opened yet on the shared UTC reference day, even while a different session has already fully closed" do
      # 07:00 UTC on 2026-08-18: 16:00 JST (Asia's 09:00-15:00 session
      # already closed an hour earlier) but only 03:00 ET (US's own
      # 09:30-16:00 session hasn't opened yet). US must stay "not
      # closed" here -- it hasn't had its own trading day yet.
      gap_time = DateTime.new!(~D[2026-08-18], ~T[07:00:00], "Etc/UTC")

      refute MarketHours.closed_for_today?(@us, gap_time)
      assert MarketHours.closed_for_today?(@asia, gap_time)
    end

    test "false during a session's own hours even when a different-timezone session has already fully closed for the shared reference day" do
      # 03:00 UTC on 2026-08-18 = 12:00 JST, mid-Asia-session.
      asia_mid_session = DateTime.new!(~D[2026-08-18], ~T[03:00:00], "Etc/UTC")

      refute MarketHours.closed_for_today?(@asia, asia_mid_session)
    end

    test "combined with all-sessions-closed-style Enum.all? semantics: both US and Asia must independently agree before treated as fully closed" do
      us_close_utc = DateTime.new!(~D[2026-08-18], ~T[20:00:00], "Etc/UTC")
      gap_time = DateTime.new!(~D[2026-08-18], ~T[07:00:00], "Etc/UTC")

      # At US close, both sessions agree closed -- version should deactivate.
      assert Enum.all?([@us, @asia], &MarketHours.closed_for_today?(&1, us_close_utc))

      # In the gap where Asia's already closed but US hasn't opened yet,
      # they must NOT both agree closed -- the version must stay active
      # until US has actually had its own trading day.
      refute Enum.all?([@us, @asia], &MarketHours.closed_for_today?(&1, gap_time))
    end

    test "deliberate behavior: late Sunday evening (local time) no longer reads as closed once the UTC calendar has already rolled to a real trading day (Monday)" do
      # 2026-07-26 (Sunday) 23:00 ET = 2026-07-27 (Monday) 03:00 UTC.
      # Anchored to UTC-Monday, a real trading day whose own 09:30 ET
      # open is still ~10.5 hours away -- must NOT read as closed, even
      # though the OLD local-day logic (seeing "Sunday", a non-trading
      # day) would have answered true regardless of clock time.
      sunday_late = DateTime.new!(~D[2026-07-26], ~T[23:00:00], "America/New_York")

      refute MarketHours.closed_for_today?(@us, sunday_late)
    end

    test "ordinary Saturday/Sunday daytime hours are unaffected by the UTC-anchoring change" do
      saturday_noon = DateTime.new!(~D[2026-07-25], ~T[12:00:00], "America/New_York")
      sunday_noon = DateTime.new!(~D[2026-07-26], ~T[12:00:00], "America/New_York")

      assert MarketHours.closed_for_today?(@us, saturday_noon)
      assert MarketHours.closed_for_today?(@us, sunday_noon)
    end

    test "closed_for_today? is independent of which time zone the caller's now argument carries, for the same instant" do
      # Same instant (2026-08-18 20:00 UTC = 2026-08-19 05:00 JST), passed
      # to the Asia check in two different zones -- must agree, since
      # correctness here must not depend on caller convention.
      now_utc = DateTime.new!(~D[2026-08-18], ~T[20:00:00], "Etc/UTC")
      now_et = DateTime.shift_zone!(now_utc, "America/New_York")

      assert MarketHours.closed_for_today?(@asia, now_utc) ==
               MarketHours.closed_for_today?(@asia, now_et)
    end
  end

  describe "today_is_a_trading_day?/2" do
    test "true on a weekday in days_of_week, regardless of enabled" do
      disabled = %{@us | enabled: false}
      # 2026-07-20 is a Monday.
      now = DateTime.new!(~D[2026-07-20], ~T[11:00:00], "America/New_York")

      assert MarketHours.today_is_a_trading_day?(@us, now)
      assert MarketHours.today_is_a_trading_day?(disabled, now)
    end

    test "false on a Saturday even when enabled" do
      now = DateTime.new!(~D[2026-08-15], ~T[11:00:00], "America/New_York")
      refute MarketHours.today_is_a_trading_day?(@us, now)
    end

    test "true on a day explicitly added to days_of_week, even if enabled is false" do
      weekend_market = %{@us | days_of_week: [6, 7], enabled: false}
      now = DateTime.new!(~D[2026-08-15], ~T[11:00:00], "America/New_York")

      assert MarketHours.today_is_a_trading_day?(weekend_market, now)
    end

    test "checks the day in the session's own timezone, not now's original zone" do
      # Same DST/timezone-crossing case as open?/2's own test above.
      now = DateTime.new!(~D[2026-08-15], ~T[23:30:00], "America/New_York")
      saturday_only = %{@us | days_of_week: [6]}

      assert MarketHours.today_is_a_trading_day?(saturday_only, now)
    end
  end
end
