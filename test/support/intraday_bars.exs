defmodule TradingCore.IntradayBars do
  @moduledoc false
  # Builds 1-minute bar fixtures for the Intraday tests, keyed by the ET
  # session date and minute of day (0 = the 09:30 bar).

  alias TradingCore.Intraday.RegularSession

  def bar(date, minute, open, high, low, close) do
    {:ok, session_open, _close} = RegularSession.bounds(date)

    %{
      timestamp:
        session_open |> DateTime.add(minute * 60, :second) |> DateTime.to_unix(:millisecond),
      open: open,
      high: high,
      low: low,
      close: close,
      volume: 1000,
      vwap: close
    }
  end

  # A bar whose open/high/low/close are all `price`.
  def flat(date, minute, price), do: bar(date, minute, price, price, price, price)

  def at_et(date, time) do
    date |> DateTime.new!(time, "America/New_York") |> DateTime.shift_zone!("Etc/UTC")
  end

  # The `n` trading days strictly before `date`, most recent first.
  def trading_days_before(date, n) do
    date
    |> Date.add(-1)
    |> Stream.iterate(&Date.add(&1, -1))
    |> Stream.filter(&(RegularSession.bounds(&1) != :error))
    |> Enum.take(n)
  end
end
