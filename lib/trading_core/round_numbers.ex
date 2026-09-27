defmodule TradingCore.RoundNumbers do
  @moduledoc """
  Moves a stop-loss or take-profit level off the crowded side of a round
  number. Pure arithmetic, no I/O; off unless a caller asks for it.

  ## Why

  Osler (Federal Reserve Bank of New York Staff Reports 125 and 150; RBS
  FX order book, 1999–2000) found conditional orders pile up at round
  numbers far beyond chance (about 9–10% at prices ending in 00, against
  about 1% if spread evenly), and pile up differently by type:

    * **Take-profits cluster exactly AT round numbers**, and prices tend to
      turn back there. A target sitting at or just past a round number
      often never fills, so pull it just in front.
    * **Stop-losses cluster just BEYOND round numbers** — stop-buys a
      little above, stop-sells a little below. Once the round number
      breaks, those stops fire together and push the price further (a
      "price cascade"), so a stop inside that zone fills late and badly.
      Move it out: `:near` (just in front of the round number — exit
      before the break) or `:far` (past the crowd zone — outlast the
      cascade). Which is better is an empirical question; the option lets
      a backtest compare them.

  The evidence is from FX; applying it to equities and options is an
  assumption to test, not a given.

  ## Geometry

  "Beyond" means past the round number in the direction the price must
  travel to reach the level. For a long position:

    * take-profit (above entry, reached by rising): zone is
      `[R, R + buffer]` → moved to `R − tick`.
    * stop-loss (below entry, reached by falling): zone is
      `[R − buffer, R]` → `:near` moves it to `R + tick`, `:far` to
      `R − buffer − tick`.

  A short mirrors both. `buffer = buffer_vol_frac × daily_vol × price`.

  ## Round-number grid

  Chosen from `:price` (default: the level itself):

    * equity at or above $10 — every $0.50 (whole dollars are on it too)
    * equity below $10 — every $0.10
    * option premium (`instrument: :option`) — every $0.05 (dimes too)

  `:grid` overrides it.
  """

  @default_buffer_vol_frac Decimal.new("0.1")
  @default_tick Decimal.new("0.01")

  @type kind :: :take_profit | :stop_loss
  @type side :: String.t() | :long | :short
  @type action :: :none | :pulled_in_front | :moved_near | :moved_far | :skipped_crosses_entry

  @doc """
  The adjusted level (a `Decimal`), snapped to `:tick_size`. See
  `adjust_detail/4` for the options and for what was done.
  """
  @spec adjust(Decimal.t(), kind(), side(), keyword()) :: Decimal.t()
  def adjust(level, kind, side, opts \\ []), do: adjust_detail(level, kind, side, opts).level

  @doc """
  Like `adjust/4`, but returns what happened, for logging:

      %{
        level: Decimal.t(),            # final, tick-snapped
        original: Decimal.t(),
        round_number: Decimal.t() | nil,  # the round number it was moved off
        action: :none | :pulled_in_front | :moved_near | :moved_far | :skipped_crosses_entry
      }

  Options:

    * `:daily_vol` — daily fraction (the same figure the stop levels use).
      Without it, and without `:buffer`, nothing moves; the level is only
      snapped to tick.
    * `:buffer_vol_frac` — zone width as a fraction of one day's move
      (default `0.1`).
    * `:buffer` — an absolute zone width in price units, instead of the
      two above.
    * `:stop_zone` — `:near` or `:far` for stop-losses (default `:far`).
    * `:price` — price used to pick the grid (default: `level`).
    * `:instrument` — `:equity` (default) or `:option`.
    * `:grid` — explicit round-number spacing.
    * `:tick_size` — default `0.01`.
    * `:entry` — if given, an adjustment that would put the level on the
      wrong side of entry is skipped (`:skipped_crosses_entry`).

  Numbers may be `Decimal`, float, integer or numeric string.
  """
  @spec adjust_detail(Decimal.t(), kind(), side(), keyword()) :: %{
          level: Decimal.t(),
          original: Decimal.t(),
          round_number: Decimal.t() | nil,
          action: action()
        }
  def adjust_detail(level, kind, side, opts \\ [])
      when kind in [:take_profit, :stop_loss] do
    level = dec(level)
    side = normalize_side(side)
    tick = opts |> Keyword.get(:tick_size, @default_tick) |> dec()
    price = opts |> Keyword.get(:price, level) |> dec()
    grid = opts |> Keyword.get(:grid) |> then(&if(&1, do: dec(&1), else: grid_for(price, opts)))

    {candidate, round_number, action} =
      case buffer(price, opts) do
        nil -> {level, nil, :none}
        buffer -> move(level, kind, side, grid, buffer, tick, Keyword.get(opts, :stop_zone, :far))
      end

    {final, round_number, action} =
      if action != :none and crosses_entry?(candidate, kind, side, Keyword.get(opts, :entry)) do
        {level, round_number, :skipped_crosses_entry}
      else
        {candidate, round_number, action}
      end

    %{
      level: snap(final, tick, snap_direction(kind, side, action)),
      original: level,
      round_number: if(action == :none, do: nil, else: round_number),
      action: action
    }
  end

  @doc "The round-number spacing for `price` (see moduledoc, \"Round-number grid\")."
  @spec grid_for(Decimal.t(), keyword()) :: Decimal.t()
  def grid_for(price, opts \\ []) do
    cond do
      Keyword.get(opts, :instrument, :equity) == :option -> Decimal.new("0.05")
      Decimal.compare(dec(price), 10) == :lt -> Decimal.new("0.10")
      true -> Decimal.new("0.50")
    end
  end

  # Long take-profit: zone [R, R + buffer], R the round number at or below.
  defp move(level, :take_profit, :long, grid, buffer, tick, _zone) do
    r = floor_to(level, grid)

    if within?(Decimal.sub(level, r), buffer),
      do: {Decimal.sub(r, tick), r, :pulled_in_front},
      else: {level, nil, :none}
  end

  # Short take-profit: zone [R − buffer, R], R the round number at or above.
  defp move(level, :take_profit, :short, grid, buffer, tick, _zone) do
    r = ceil_to(level, grid)

    if within?(Decimal.sub(r, level), buffer),
      do: {Decimal.add(r, tick), r, :pulled_in_front},
      else: {level, nil, :none}
  end

  # Long stop (a stop-sell): zone [R − buffer, R], R the round number at or above.
  defp move(level, :stop_loss, :long, grid, buffer, tick, zone) do
    r = ceil_to(level, grid)

    cond do
      not within?(Decimal.sub(r, level), buffer) -> {level, nil, :none}
      zone == :near -> {Decimal.add(r, tick), r, :moved_near}
      true -> {r |> Decimal.sub(buffer) |> Decimal.sub(tick), r, :moved_far}
    end
  end

  # Short stop (a stop-buy): zone [R, R + buffer], R the round number at or below.
  defp move(level, :stop_loss, :short, grid, buffer, tick, zone) do
    r = floor_to(level, grid)

    cond do
      not within?(Decimal.sub(level, r), buffer) -> {level, nil, :none}
      zone == :near -> {Decimal.sub(r, tick), r, :moved_near}
      true -> {r |> Decimal.add(buffer) |> Decimal.add(tick), r, :moved_far}
    end
  end

  defp within?(distance, buffer), do: Decimal.compare(distance, buffer) != :gt

  defp buffer(price, opts) do
    cond do
      b = Keyword.get(opts, :buffer) ->
        dec(b)

      vol = Keyword.get(opts, :daily_vol) ->
        vol = dec(vol)

        if Decimal.compare(vol, 0) == :gt do
          frac = opts |> Keyword.get(:buffer_vol_frac, @default_buffer_vol_frac) |> dec()
          price |> Decimal.mult(vol) |> Decimal.mult(frac)
        end

      true ->
        nil
    end
  end

  # A take-profit must stay on the profit side of entry, a stop on the
  # loss side.
  defp crosses_entry?(_level, _kind, _side, nil), do: false

  defp crosses_entry?(level, kind, side, entry) do
    wanted =
      case {kind, side} do
        {:take_profit, :long} -> :gt
        {:stop_loss, :short} -> :gt
        {:take_profit, :short} -> :lt
        {:stop_loss, :long} -> :lt
      end

    Decimal.compare(level, dec(entry)) != wanted
  end

  # A :far stop snaps further away from the round number so it stays out
  # of the zone; everything else rounds to the nearest tick.
  defp snap_direction(:stop_loss, :long, :moved_far), do: :floor
  defp snap_direction(:stop_loss, :short, :moved_far), do: :ceiling
  defp snap_direction(_kind, _side, _action), do: :half_up

  defp snap(level, tick, rounding) do
    level |> Decimal.div(tick) |> Decimal.round(0, rounding) |> Decimal.mult(tick)
  end

  defp floor_to(x, step),
    do: x |> Decimal.div(step) |> Decimal.round(0, :floor) |> Decimal.mult(step)

  defp ceil_to(x, step),
    do: x |> Decimal.div(step) |> Decimal.round(0, :ceiling) |> Decimal.mult(step)

  defp normalize_side(s) when s in ["short", :short], do: :short
  defp normalize_side(_long), do: :long

  defp dec(%Decimal{} = d), do: d
  defp dec(n) when is_integer(n), do: Decimal.new(n)
  defp dec(n) when is_float(n), do: Decimal.from_float(n)
  defp dec(s) when is_binary(s), do: Decimal.new(s)
end
