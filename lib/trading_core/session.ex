defmodule TradingCore.Session do
  @moduledoc """
  Named, canonical session-boundary functions — the injectable
  `DateTime.t() -> term()` shape `TradingCore.Signal.Compute`'s `:vwap`/
  `:volume` kinds accept as `params["session_reset"]` (see that module's
  own "Session boundaries" moduledoc section). A caller (a live
  `trading_signal` process, `trading_backtest` replaying historical data)
  passes one of these functions rather than writing its own closure, so
  every caller resets on the exact same boundary rather than each
  hand-rolling a slightly different rule that happens to agree today.

  ## Why `us_equities/1` is built on `TradingCore.MarketHours`, not a
  fresh port of `TradingSignal.Signals.CumulativeVolume`'s own rule

  `CumulativeVolume`'s `current_session_date/1` (the rule actually running
  live today) is a simple, uncomplicated 9:30am America/New_York boundary
  check with no weekend/holiday awareness and no cross-timezone "today"
  anchoring — it has never needed either, since a `CumulativeVolume`
  tracker's own state resets implicitly every time its owning
  `TradingSignal.Signals.Process` restarts (which, in practice, happens at
  least daily). A `TradingCore.Signal.Compute` state, by contrast, is
  meant to survive exactly the kind of long, uninterrupted run (a replay
  over weeks/months of history, or a live process staying up across a
  weekend) where those blind spots are real: a naive rule sees `Sunday
  16:00 ET < Monday 09:30 ET` and calls that "still Friday's session,"
  quietly failing to reset across the entire weekend gap.

  `TradingCore.MarketHours` has already absorbed three separate real
  production incidents around exactly this class of bug (weekend/holiday
  false-positives, "closed" vs. "not yet open" conflation, and
  cross-timezone "today" ambiguity — see that module's own moduledoc for
  each). Building `us_equities/1` on `MarketHours.today_open/2` inherits
  all three fixes for free, rather than reintroducing the first one by
  porting `CumulativeVolume`'s simpler rule verbatim. This is a
  deliberate, small behavior improvement over what's live today, not a
  faithful reproduction of it — call this out explicitly wherever it's
  wired in as the new canonical default, since it's the one piece of this
  migration that isn't purely "same behavior, new plumbing."

  `today_open/2`'s own contract only promises a correct answer for
  *today's* 9:30am ET boundary in `now`'s own local terms, with no
  weekend/holiday awareness of its own (see its own moduledoc — that's a
  deliberate design choice there, not a gap: `next_close/2`/`today_open/2`
  are meant as raw time-math a caller layers its own day-of-week gate on
  top of, same as `open?/2`/`closed_for_today?/2` do internally).
  `us_equities/1` supplies that gate itself, via `today_is_a_trading_day?/2`
  — a Saturday tick's session bucket resolves to the most recent actual
  trading day's open (Friday's), walking back one calendar day at a time,
  not Saturday's own well-defined-but-meaningless 9:30am instant. Without
  this, two Saturday ticks would still agree with each other (a
  self-consistent, if pointless, bucket), but a Friday-afternoon tick and
  a Saturday tick would incorrectly land in *different* buckets — a
  spurious mid-weekend reset that has nothing to do with an actual
  session boundary.
  """

  alias TradingCore.MarketHours
  alias TradingCore.MarketHours.Session

  @us_equities_session %Session{
    name: "US",
    timezone: "America/New_York",
    start_time: ~T[09:30:00],
    end_time: ~T[16:00:00],
    days_of_week: [1, 2, 3, 4, 5]
  }

  @doc """
  The US-equities session boundary for `now` (UTC) — two `DateTime`s
  belong to the same session iff this returns the same value for both.
  The canonical `session_reset` function for every `:vwap`/`:volume`
  `TradingCore.Signal.Spec` scoped to US equities, live or replayed.

  A pre-open tick (e.g. 5am ET Tuesday) belongs to the *prior trading
  day's* session (Monday's), not a fresh bucket of its own —
  `MarketHours.today_open/2` alone does NOT give this for free (confirmed:
  it answers for `now`'s own local calendar day unconditionally, so 5am
  ET Tuesday and 11pm ET Monday resolve to two different `today_open/2`
  results, which would incorrectly reset mid-pre-market at local midnight
  rather than at 9:30am). This function walks `now` back one calendar day
  at a time — first whenever it falls before that day's own open, then
  further while that day isn't a trading day at all (skipping a weekend/
  holiday gap entirely) — before calling `today_open/2` for the day it
  lands on. The same "pre-open belongs to the prior session" shape
  `TradingSignal.Signals.CumulativeVolume.current_session_date/1` has,
  reproduced here on top of `MarketHours`'s own DST/timezone-correct,
  day-of-week-aware primitives rather than a fresh `DateTime.shift_zone!/2`
  call with no calendar awareness of its own.
  """
  @spec us_equities(DateTime.t()) :: DateTime.t()
  def us_equities(%DateTime{} = now) do
    {:ok, local_now} = DateTime.shift_zone(now, @us_equities_session.timezone)
    reference_date = walk_back_to_trading_day(local_now)

    {:ok, reference_noon} =
      DateTime.new(reference_date, ~T[12:00:00], @us_equities_session.timezone)

    MarketHours.today_open(@us_equities_session, reference_noon)
  end

  # local_now's own calendar day, unless local_now falls before that
  # day's own open (walk back one day) or that day isn't a trading day at
  # all (keep walking back until one is found) — bounded to 10 days so a
  # misconfigured @us_equities_session (e.g. an accidentally-empty
  # days_of_week) fails loudly with a clear error rather than looping
  # forever; ten real calendar days comfortably covers every actual US
  # market holiday cluster (the longest is the four-day Thanksgiving/
  # Christmas/New Year's stretch, never more than 3-4 consecutive
  # non-trading days).
  defp walk_back_to_trading_day(local_now, attempts_left \\ 10)

  defp walk_back_to_trading_day(_local_now, 0) do
    raise ArgumentError,
          "TradingCore.Session.us_equities/1: no trading day found within 10 days — " <>
            "check @us_equities_session's days_of_week"
  end

  defp walk_back_to_trading_day(local_now, attempts_left) do
    today = DateTime.to_date(local_now)

    {:ok, today_open} = DateTime.new(today, @us_equities_session.start_time, local_now.time_zone)

    trading_day? = MarketHours.today_is_a_trading_day?(@us_equities_session, local_now)
    before_open? = DateTime.compare(local_now, today_open) == :lt

    if trading_day? and not before_open? do
      today
    else
      yesterday_noon = DateTime.new!(Date.add(today, -1), ~T[12:00:00], local_now.time_zone)
      walk_back_to_trading_day(yesterday_noon, attempts_left - 1)
    end
  end
end
