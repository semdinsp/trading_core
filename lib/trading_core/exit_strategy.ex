defmodule TradingCore.ExitStrategy do
  @moduledoc """
  Ratchet/trailing-stop math — extracted from
  `TradingSystem.Trading.ExitStrategy` into this shared library, same
  pattern/motivation as `TradingCore.RiskControls`/`TradingCore.RuleEngine`/
  `TradingCore.PositionSizing` (see each of those modules' own moduledocs):
  one place to fix this arithmetic if it ever changes, not two copies (a
  live one in `trading_system` and a backtest one here) that can silently
  drift apart.

  `TradingSystem.Trading.ExitStrategy.check/3` reads its running state
  (`ratcheted_at`, `trailing_high_water_mark`) off a `%StrategyRun{}`'s
  `state_snapshot` field and its config off `run.strategy_version.params`.
  This module takes the exact same inputs as plain values instead, so a
  live wrapper can (in a future, out-of-scope-for-this-task refactor)
  become a thin shim: pull `entry_price`/`direction`/`state_snapshot` off
  the run, pull `exit_strategy` config off the version's params, call
  `check/5` here, and translate the result back into a `state_snapshot`
  update — unchanged math, byte-for-byte, between live and backtest.

  Supported methods (config `"method"` key), identical semantics to the
  live module:

    * `"ratchet"` — a single, one-time ratchet. Once unrealized return (in
      the position's favor) first reaches `trigger_pct`, the take-profit
      cap is removed and the stop-loss is raised/lowered to lock in
      `lock_pct`. Fires at most once — `state.ratcheted_at` (any non-`nil`
      value; this module never inspects its contents, only its
      presence/absence, since backtest replay has no real timestamp source
      for this field beyond "did it already fire") gates re-firing, same
      as the live module's `ratcheted?/1`.

    * `"trailing"` — continuous re-ratcheting. The stop is kept `trail_pct`
      behind the run's own running high-water-mark (`state.trailing_high_water_mark`,
      defaulting to `entry_price` when absent — no favorable move has
      happened yet), tightening every time a new favorable extreme is
      reached and never loosening. Returns `:no_ratchet` (not `:trail`) on
      a bar that doesn't improve on the existing high-water-mark.

  `nil`/missing config, or a config with an unrecognized `"method"`, always
  returns `:no_ratchet` — a version with no `exit_strategy` configured (or
  a malformed one) behaves exactly as if this module weren't consulted at
  all, matching `TradingSystem.Trading.ExitStrategy.check/3`'s own
  "no config or unrecognized" clause.

  All arithmetic uses `Decimal`, never floats.

  ## Usage

      iex> state = %{ratcheted_at: nil}
      iex> config = %{"method" => "ratchet", "trigger_pct" => 5, "lock_pct" => 2}
      iex> TradingCore.ExitStrategy.check(Decimal.new(100), Decimal.new(106), "long", config, state)
      {:ratchet, Decimal.new("102"), %{ratcheted_at: true}}

      iex> state = %{trailing_high_water_mark: nil}
      iex> config = %{"method" => "trailing", "trail_pct" => 3}
      iex> TradingCore.ExitStrategy.check(Decimal.new(100), Decimal.new(110), "long", config, state)
      {:trail, Decimal.new("106.7"), %{trailing_high_water_mark: Decimal.new(110)}}
  """

  @type direction :: String.t()
  @type state :: %{
          optional(:ratcheted_at) => term(),
          optional(:trailing_high_water_mark) => Decimal.t() | nil
        }

  @doc """
  Checks whether a run should ratchet/trail right now, given `entry_price`,
  `current_price`, `direction` (`"long"`/`"short"`), the version's
  `exit_strategy` config, and the run's own running `state` (a plain map
  with whatever of `:ratcheted_at`/`:trailing_high_water_mark` is already
  known — both optional, absent/`nil` meaning "hasn't happened yet").

  Returns:

    * `{:ratchet, new_stop_loss_price, state_updates}` — `"ratchet"` fired
      for the first time this call. `state_updates` is
      `%{ratcheted_at: true}`; merge it into the run's own persisted state
      (a caller with a real clock may prefer to stamp an actual timestamp
      instead of literal `true` — this module only ever checks
      presence/absence, so either works).
    * `{:trail, new_stop_loss_price, state_updates}` — `"trailing"`'s
      high-water-mark advanced this bar. `state_updates` is
      `%{trailing_high_water_mark: new_high_water_mark}`.
    * `:no_ratchet` — nothing to do: no config, unrecognized method,
      already ratcheted (for `"ratchet"`), or no new favorable extreme
      (for `"trailing"`).
  """
  @spec check(Decimal.t(), Decimal.t(), direction(), map() | nil, state()) ::
          {:ratchet, Decimal.t(), map()} | {:trail, Decimal.t(), map()} | :no_ratchet
  def check(entry_price, current_price, direction, config, state \\ %{})

  def check(entry_price, current_price, direction, %{"method" => "ratchet"} = config, state) do
    check_ratchet(entry_price, current_price, direction, config, state)
  end

  def check(entry_price, current_price, direction, %{"method" => "trailing"} = config, state) do
    check_trailing(entry_price, current_price, direction, config, state)
  end

  def check(_entry_price, _current_price, _direction, _no_config_or_unrecognized, _state),
    do: :no_ratchet

  defp check_ratchet(entry_price, current_price, direction, config, state) do
    with false <- ratcheted?(state),
         true <- not is_nil(entry_price),
         true <- trigger_reached?(entry_price, current_price, direction, config) do
      {:ratchet, locked_stop_price(entry_price, direction, config), %{ratcheted_at: true}}
    else
      _ -> :no_ratchet
    end
  end

  defp ratcheted?(%{ratcheted_at: value}), do: not is_nil(value)
  defp ratcheted?(_state), do: false

  defp check_trailing(entry_price, current_price, direction, %{"trail_pct" => trail_pct}, state) do
    if is_nil(entry_price) do
      :no_ratchet
    else
      high_water_mark = trailing_high_water_mark(state, entry_price)
      new_high_water_mark = more_favorable(high_water_mark, current_price, direction)

      if Decimal.eq?(new_high_water_mark, high_water_mark) do
        :no_ratchet
      else
        {:trail, trailing_stop_price(new_high_water_mark, direction, trail_pct),
         %{trailing_high_water_mark: new_high_water_mark}}
      end
    end
  end

  defp check_trailing(_entry_price, _current_price, _direction, _config_missing_trail_pct, _state),
    do: :no_ratchet

  defp trailing_high_water_mark(%{trailing_high_water_mark: %Decimal{} = stored}, _entry_price),
    do: stored

  defp trailing_high_water_mark(_state, entry_price), do: entry_price

  defp more_favorable(high_water_mark, current_price, "short") do
    Decimal.min(high_water_mark, current_price)
  end

  defp more_favorable(high_water_mark, current_price, _long) do
    Decimal.max(high_water_mark, current_price)
  end

  defp trailing_stop_price(high_water_mark, direction, trail_pct) do
    fraction = fraction(trail_pct)

    case direction do
      "short" -> Decimal.mult(high_water_mark, Decimal.add(1, fraction))
      _long -> Decimal.mult(high_water_mark, Decimal.sub(1, fraction))
    end
  end

  defp trigger_reached?(entry_price, current_price, direction, %{"trigger_pct" => trigger_pct}) do
    threshold = fraction(trigger_pct)

    case direction do
      "short" ->
        Decimal.compare(
          Decimal.div(Decimal.sub(entry_price, current_price), entry_price),
          threshold
        ) != :lt

      _long ->
        Decimal.compare(
          Decimal.div(Decimal.sub(current_price, entry_price), entry_price),
          threshold
        ) != :lt
    end
  end

  defp trigger_reached?(_entry_price, _current_price, _direction, _config_missing_trigger_pct),
    do: false

  defp locked_stop_price(entry_price, direction, %{"lock_pct" => lock_pct}) do
    fraction = fraction(lock_pct)

    case direction do
      "short" -> Decimal.mult(entry_price, Decimal.sub(1, fraction))
      _long -> Decimal.mult(entry_price, Decimal.add(1, fraction))
    end
  end

  defp locked_stop_price(entry_price, _direction, _config_missing_lock_pct) do
    # Same "resolve rather than assert" spirit as
    # TradingCore.RiskControls.check/4 — trigger_reached?/4 already
    # requires "trigger_pct", but "lock_pct" is a separate required key a
    # malformed config could still omit; fall back to entry_price itself
    # (no lock movement) rather than raising mid-replay.
    entry_price
  end

  defp fraction(percent), do: Decimal.div(Decimal.new(to_string(percent)), 100)
end
