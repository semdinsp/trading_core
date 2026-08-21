defmodule TradingCore.RiskControls do
  @moduledoc """
  Stop-loss/take-profit price levels and hit-checks — extracted from
  `trading_system`'s `TradingSystem.Trading.RiskControls`/
  `TradingSystem.Trading.PositionExitCheck` into this shared library so
  `trading_system`'s own live/paper position tracking and `trading_live`'s
  `StrategyStockMonitor` compute and check the exact same levels, same as
  `TradingCore.RuleEngine` already does for rule-tree evaluation (see that
  module's own moduledoc) — one place to fix if the formula ever changes,
  not two copies that can silently drift apart.

  `trading_system`'s `StrategyVersion.rules["exit"]` (mirrored on
  `trading_live`'s `LiveStrategy.rule_tree["exit"]`) is a genuinely
  optional, structurally run-local-only rule — see
  `TradingSystem.Trading.PositionExitCheck`'s own moduledoc, "a version's
  exit rule structurally can only ever reference run-local values, never
  a real signal." An empty/missing exit rule does **not** mean "exit
  immediately" (that's `TradingCore.RuleEngine.evaluate/2`'s "vacuously
  satisfied" behavior for an *entry* rule, which is the right default
  there) — for an exit, it means "no custom exit condition was authored;
  fall back to this stop-loss/take-profit"). A caller must not treat a
  vacuously-true `RuleEngine.evaluate/2` result on an empty exit rule as
  a real exit signal; check stop-loss/take-profit here instead whenever
  the exit rule is empty or absent.

  All arithmetic uses `Decimal`, never floats.
  """

  @default_stop_loss_percent Decimal.new("0.05")
  @default_take_profit_percent Decimal.new("0.10")

  @doc "The config used when no risk_controls are set — exposed so callers/forms can show what 'default' means."
  @spec default_config() :: map()
  def default_config do
    %{
      "method" => "percent_of_entry",
      "stop_loss_percent" => Decimal.to_float(@default_stop_loss_percent) * 100,
      "take_profit_percent" => Decimal.to_float(@default_take_profit_percent) * 100
    }
  end

  @doc """
  Calculates `{stop_loss_price, take_profit_price}` from `entry_price`, a
  `risk_controls` config map (e.g. a `StrategyVersion`'s
  `params["risk_controls"]`, or `nil`/missing to use the default), and
  `direction` (`"long"` or `"short"`).

  For `"long"`, stop-loss sits below entry and take-profit above — a
  rising price is favorable. For `"short"`, this inverts: stop-loss sits
  above entry (the position loses as price rises) and take-profit below
  (the position gains as price falls). `direction` defaults to `"long"`.

  Only `"percent_of_entry"` is implemented today (`"atr"` needs an ATR
  data source that doesn't exist anywhere in this stack yet — see
  `TradingSystem.Trading.RiskControls`'s own moduledoc for why that
  method is deliberately left unimplemented rather than stubbed) — any
  other or missing `"method"` falls back to `percent_of_entry` with the
  default percentages, same as a `StrategyVersion` with no
  `risk_controls` key at all (every version created before risk_controls
  existed).
  """
  @spec levels(Decimal.t(), map() | nil, String.t()) :: {Decimal.t(), Decimal.t()}
  def levels(entry_price, risk_controls_config, direction \\ "long")

  def levels(entry_price, %{"method" => "percent_of_entry"} = config, direction) do
    percent_of_entry_levels(entry_price, config, direction)
  end

  def levels(entry_price, _config, direction) do
    percent_of_entry_levels(
      entry_price,
      %{
        "stop_loss_percent" => Decimal.to_float(@default_stop_loss_percent) * 100,
        "take_profit_percent" => Decimal.to_float(@default_take_profit_percent) * 100
      },
      direction
    )
  end

  defp percent_of_entry_levels(
         entry_price,
         %{
           "stop_loss_percent" => stop_loss_percent,
           "take_profit_percent" => take_profit_percent
         },
         direction
       ) do
    stop_loss_fraction = Decimal.div(Decimal.new(to_string(stop_loss_percent)), 100)
    take_profit_fraction = Decimal.div(Decimal.new(to_string(take_profit_percent)), 100)

    case direction do
      "short" ->
        stop_loss_price = Decimal.mult(entry_price, Decimal.add(1, stop_loss_fraction))
        take_profit_price = Decimal.mult(entry_price, Decimal.sub(1, take_profit_fraction))
        {stop_loss_price, take_profit_price}

      _long ->
        stop_loss_price = Decimal.mult(entry_price, Decimal.sub(1, stop_loss_fraction))
        take_profit_price = Decimal.mult(entry_price, Decimal.add(1, take_profit_fraction))
        {stop_loss_price, take_profit_price}
    end
  end

  @doc """
  `true` if `current_price` has crossed `stop_loss_price` against the
  position — for `"long"`, fallen to or through it (current <= stop);
  for `"short"`, risen to or through it (current >= stop). `nil` (no
  stop-loss set) never hits. `direction` defaults to `"long"`.
  """
  @spec hit_stop_loss?(Decimal.t() | nil, Decimal.t(), String.t()) :: boolean()
  def hit_stop_loss?(stop_loss_price, current_price, direction \\ "long")
  def hit_stop_loss?(nil, _current_price, _direction), do: false

  def hit_stop_loss?(stop_loss_price, current_price, "short") do
    Decimal.compare(current_price, stop_loss_price) != :lt
  end

  def hit_stop_loss?(stop_loss_price, current_price, _long) do
    Decimal.compare(current_price, stop_loss_price) != :gt
  end

  @doc """
  `true` if `current_price` has crossed `take_profit_price` in the
  position's favor — for `"long"`, risen to or through it (current >=
  target); for `"short"`, fallen to or through it (current <= target).
  `nil` (no take-profit set) never hits. `direction` defaults to `"long"`.
  """
  @spec hit_take_profit?(Decimal.t() | nil, Decimal.t(), String.t()) :: boolean()
  def hit_take_profit?(take_profit_price, current_price, direction \\ "long")
  def hit_take_profit?(nil, _current_price, _direction), do: false

  def hit_take_profit?(take_profit_price, current_price, "short") do
    Decimal.compare(current_price, take_profit_price) != :gt
  end

  def hit_take_profit?(take_profit_price, current_price, _long) do
    Decimal.compare(current_price, take_profit_price) != :lt
  end

  @doc """
  `{:stopped_out, snapshot} | {:target_hit, snapshot} | nil` for a
  position whose `stop_loss_price`/`take_profit_price` are already known
  (computed once at entry via `levels/3`) — `:stopped_out` takes priority
  if somehow both are true at once (cannot happen with well-formed
  levels on either side, but resolving the tie explicitly is cheaper
  than asserting it can't occur). `direction` defaults to `"long"`.

  `snapshot` carries the three prices that decided the check — useful
  for recording "how far past the stop did this actually close" without
  needing the price feed's own history, same shape
  `TradingSystem.Trading.PositionExitCheck.exit_reason/3` already
  returns (`"run_current_price"`/`"run_stop_loss_price"`/
  `"run_take_profit_price"` — kept as these exact string keys since a
  hand-authored `StrategyVersion` exit rule can reference them by name,
  see `TradingCore.RuleEngine`'s moduledoc on `"run_"`-prefixed names).
  """
  @spec check(Decimal.t() | nil, Decimal.t() | nil, Decimal.t(), String.t()) ::
          {:stopped_out | :target_hit, map()} | nil
  def check(stop_loss_price, take_profit_price, current_price, direction \\ "long") do
    snapshot = %{
      "run_current_price" => current_price,
      "run_stop_loss_price" => stop_loss_price,
      "run_take_profit_price" => take_profit_price
    }

    cond do
      hit_stop_loss?(stop_loss_price, current_price, direction) -> {:stopped_out, snapshot}
      hit_take_profit?(take_profit_price, current_price, direction) -> {:target_hit, snapshot}
      true -> nil
    end
  end
end
