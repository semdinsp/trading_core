defmodule TradingCore.Intraday.RegularSession do
  @moduledoc """
  The US-equities regular session for one date, and minute bars sliced
  to it. Shared by `TradingCore.Intraday.OpeningRange` and
  `TradingCore.Intraday.NoiseBand`.

  The session opens at 09:30 America/New_York and closes at 16:00, or at
  the early close from `TradingCore.MarketHours.early_close/2` on a half
  day. Weekends and `TradingCore.MarketHours.holiday?/2` dates have no
  session. Times are converted with the tz database, so DST is handled.

  ## Bars

  A bar is a map whose `:timestamp` is the bar's **start** in Unix
  milliseconds UTC (Polygon's aggregate convention) or a `DateTime`, plus
  `:open`, `:high`, `:low`, `:close` as numbers, Decimals or numeric
  strings. A 1-minute bar starting at 09:30:00 ET is minute 0. A bar
  belongs to the regular session when `open <= start < close`, so
  extended-hours bars are dropped. Bars with a missing or unparseable
  timestamp or price are dropped rather than raising.
  """

  alias TradingCore.MarketHours
  alias TradingCore.Regime.Decimals

  @market "US_EQUITIES"
  @timezone "America/New_York"
  @open_time ~T[09:30:00]
  @close_time ~T[16:00:00]

  @type bar :: %{
          required(:timestamp) => integer() | DateTime.t(),
          optional(atom()) => term()
        }

  @typedoc "A bar normalized to the session: minute of day plus Decimal prices."
  @type session_bar :: %{
          minute: non_neg_integer(),
          open: Decimal.t(),
          high: Decimal.t(),
          low: Decimal.t(),
          close: Decimal.t()
        }

  @doc "`{:ok, open_utc, close_utc}` for `date`'s regular session, or `:error` on a weekend or holiday."
  @spec bounds(Date.t()) :: {:ok, DateTime.t(), DateTime.t()} | :error
  def bounds(%Date{} = date) do
    if Date.day_of_week(date) in 1..5 and not MarketHours.holiday?(@market, date) do
      close_time =
        case MarketHours.early_close(@market, date) do
          {time, _zone} -> time
          nil -> @close_time
        end

      {:ok, utc(date, @open_time), utc(date, close_time)}
    else
      :error
    end
  end

  def bounds(_date), do: :error

  @doc "Length of `date`'s regular session in minutes (390, or fewer on a half day); `nil` with no session."
  @spec length_minutes(Date.t()) :: pos_integer() | nil
  def length_minutes(date) do
    case bounds(date) do
      {:ok, open, close} -> div(DateTime.diff(close, open), 60)
      :error -> nil
    end
  end

  @doc """
  Minutes since `session_date`'s 09:30 ET open (floored), or `nil` when
  `at` is outside that session's `[open, close)` or there's no session.
  """
  @spec minute_of_day(DateTime.t(), Date.t()) :: non_neg_integer() | nil
  def minute_of_day(%DateTime{} = at, session_date) do
    with {:ok, open, close} <- bounds(session_date),
         true <- DateTime.compare(at, open) != :lt and DateTime.compare(at, close) == :lt do
      div(DateTime.diff(at, open), 60)
    else
      _ -> nil
    end
  end

  def minute_of_day(_at, _session_date), do: nil

  @doc """
  `date`'s regular-session bars from `bars`, normalized and sorted by
  minute. When two bars share a minute, the later one in `bars` wins.
  `:error` when `date` has no session.
  """
  @spec bars_for(Enumerable.t(), Date.t()) :: {:ok, [session_bar()]} | :error
  def bars_for(bars, date) do
    with {:ok, open, close} <- bounds(date) do
      session_bars =
        bars
        |> Enum.flat_map(fn bar ->
          with {:ok, start} <- start_time(bar),
               true <-
                 DateTime.compare(start, open) != :lt and DateTime.compare(start, close) == :lt,
               {:ok, normalized} <- normalize(bar, div(DateTime.diff(start, open), 60)) do
            [normalized]
          else
            _ -> []
          end
        end)
        |> Map.new(&{&1.minute, &1})
        |> Map.values()
        |> Enum.sort_by(& &1.minute)

      {:ok, session_bars}
    end
  end

  @doc "The ET calendar date a bar starts on, or `:error` for an unparseable timestamp."
  @spec local_date(bar()) :: {:ok, Date.t()} | :error
  def local_date(bar) do
    with {:ok, start} <- start_time(bar),
         {:ok, local} <- DateTime.shift_zone(start, @timezone) do
      {:ok, DateTime.to_date(local)}
    else
      _ -> :error
    end
  end

  @doc "A bar's start as a UTC `DateTime`, or `:error`."
  @spec start_time(term()) :: {:ok, DateTime.t()} | :error
  def start_time(%{timestamp: %DateTime{} = at}), do: {:ok, at}

  def start_time(%{timestamp: ms}) when is_integer(ms) do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, at} -> {:ok, at}
      {:error, _} -> :error
    end
  end

  def start_time(_bar), do: :error

  defp normalize(bar, minute) do
    with {:ok, open} <- Decimals.parse(Map.get(bar, :open), :pos, []),
         {:ok, high} <- Decimals.parse(Map.get(bar, :high), :pos, []),
         {:ok, low} <- Decimals.parse(Map.get(bar, :low), :pos, []),
         {:ok, close} <- Decimals.parse(Map.get(bar, :close), :pos, []) do
      {:ok, %{minute: minute, open: open, high: high, low: low, close: close}}
    end
  end

  defp utc(date, time) do
    date |> DateTime.new!(time, @timezone) |> DateTime.shift_zone!("Etc/UTC")
  end
end
