defmodule TradingCore.SessionTest do
  use ExUnit.Case, async: true

  alias TradingCore.Session

  defp et(date, time), do: DateTime.new!(date, time, "America/New_York")
  defp utc(dt), do: DateTime.shift_zone!(dt, "Etc/UTC")

  describe "us_equities/1" do
    test "two ticks on the same trading day, both after open, share a bucket" do
      morning = et(~D[2026-08-24], ~T[10:00:00]) |> utc()
      afternoon = et(~D[2026-08-24], ~T[15:00:00]) |> utc()

      assert Session.us_equities(morning) == Session.us_equities(afternoon)
    end

    test "a post-open tick and the next day's pre-open tick land in different buckets" do
      monday_10am = et(~D[2026-08-24], ~T[10:00:00]) |> utc()
      tuesday_10am = et(~D[2026-08-25], ~T[10:00:00]) |> utc()

      refute Session.us_equities(monday_10am) == Session.us_equities(tuesday_10am)
    end

    test "a pre-open tick belongs to the prior day's session, not a fresh bucket" do
      monday_11pm = et(~D[2026-08-24], ~T[23:00:00]) |> utc()
      tuesday_5am = et(~D[2026-08-25], ~T[05:00:00]) |> utc()

      assert Session.us_equities(monday_11pm) == Session.us_equities(tuesday_5am)
    end

    test "the whole Friday-close-to-Monday-open weekend gap is one unbroken session" do
      friday_3pm = et(~D[2026-08-21], ~T[15:00:00]) |> utc()
      saturday_noon = et(~D[2026-08-22], ~T[12:00:00]) |> utc()
      sunday_11pm = et(~D[2026-08-23], ~T[23:00:00]) |> utc()
      monday_5am = et(~D[2026-08-24], ~T[05:00:00]) |> utc()

      bucket = Session.us_equities(friday_3pm)

      assert Session.us_equities(saturday_noon) == bucket
      assert Session.us_equities(sunday_11pm) == bucket
      assert Session.us_equities(monday_5am) == bucket
    end

    test "monday's post-open session is a fresh bucket, distinct from the prior weekend" do
      friday_3pm = et(~D[2026-08-21], ~T[15:00:00]) |> utc()
      monday_10am = et(~D[2026-08-24], ~T[10:00:00]) |> utc()

      refute Session.us_equities(friday_3pm) == Session.us_equities(monday_10am)
    end

    test "returns a DateTime at the resolved session's 9:30am ET open, in UTC" do
      tuesday_10am = et(~D[2026-08-25], ~T[10:00:00]) |> utc()

      assert Session.us_equities(tuesday_10am) == et(~D[2026-08-25], ~T[09:30:00]) |> utc()
    end
  end
end
