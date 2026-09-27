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

  Methods:

    * `"percent_of_entry"` — `"stop_loss_percent"`/`"take_profit_percent"`
      of `entry_price`.
    * `"volatility_multiple"` — `"sl_vol_mult"`/`"tp_vol_mult"` times the
      caller's `daily_vol` (see `resolve_levels/4`), passed as
      `opts[:daily_vol]`. Falls back to `percent_of_entry` when it can't
      apply; use `resolve_levels/4` to learn which method was used.

  Any other or missing `"method"` (e.g. `"atr"`, which the live apps have
  no data source for) falls back to `percent_of_entry` with the default
  percentages, same as a `StrategyVersion` with no `risk_controls` key at
  all (every version created before risk_controls existed).

  `levels/3` (no opts) is unchanged for every existing caller.
  """
  @spec levels(Decimal.t(), map() | nil, String.t(), keyword()) :: {Decimal.t(), Decimal.t()}
  def levels(entry_price, risk_controls_config, direction \\ "long", opts \\ []) do
    %{stop_loss: stop_loss, take_profit: take_profit} =
      resolve_levels(entry_price, risk_controls_config, direction, opts)

    {stop_loss, take_profit}
  end

  @doc """
  Same levels as `levels/4`, plus which method actually produced them:

      %{
        stop_loss: Decimal.t(),
        take_profit: Decimal.t(),
        method: "percent_of_entry" | "volatility_multiple",
        daily_vol: Decimal.t() | nil,       # the vol used, when method is volatility_multiple
        fallback_reason: nil | :no_daily_vol | :missing_multiples | :invalid_level
      }

  ## `"volatility_multiple"`

  Config keys: `"sl_vol_mult"`, `"tp_vol_mult"` (positive numbers), and
  optionally `"stop_loss_percent"`/`"take_profit_percent"` for the
  fallback. `opts[:daily_vol]` is a daily fraction, not annualized — the
  number `TradingCore.PositionSizing.resolve_volatility_target_with_estimate/4`
  returns and `TradingCore.Volatility.ewma_daily_vol/2` reproduces.
  `Decimal`, float, integer or numeric string.

      long:  SL = entry − sl_vol_mult × daily_vol × entry
             TP = entry + tp_vol_mult × daily_vol × entry
      short: mirrored (SL above, TP below)

  Falls back to `percent_of_entry` — using the config's own percent fields
  if both are present, else the defaults — and says why in
  `:fallback_reason`:

    * `:no_daily_vol` — `daily_vol` missing, unparseable, or not positive.
    * `:missing_multiples` — either multiple missing or not positive.
    * `:invalid_level` — the stop would be at or below zero (a long with
      `sl_vol_mult × daily_vol >= 1`).

  Pure: no I/O and no bar history at call time.
  """
  @spec resolve_levels(Decimal.t(), map() | nil, String.t(), keyword()) :: %{
          stop_loss: Decimal.t(),
          take_profit: Decimal.t(),
          method: String.t(),
          daily_vol: Decimal.t() | nil,
          fallback_reason: nil | :no_daily_vol | :missing_multiples | :invalid_level
        }
  def resolve_levels(entry_price, risk_controls_config, direction \\ "long", opts \\ [])

  def resolve_levels(entry_price, %{"method" => "volatility_multiple"} = config, direction, opts) do
    with {:ok, daily_vol} <- positive(Keyword.get(opts, :daily_vol), :no_daily_vol),
         {:ok, sl_mult} <- positive(Map.get(config, "sl_vol_mult"), :missing_multiples),
         {:ok, tp_mult} <- positive(Map.get(config, "tp_vol_mult"), :missing_multiples),
         {:ok, stop_loss, take_profit} <-
           vol_levels(entry_price, daily_vol, sl_mult, tp_mult, direction) do
      %{
        stop_loss: stop_loss,
        take_profit: take_profit,
        method: "volatility_multiple",
        daily_vol: daily_vol,
        fallback_reason: nil
      }
    else
      {:error, reason} ->
        fallback_config =
          if Map.has_key?(config, "stop_loss_percent") and
               Map.has_key?(config, "take_profit_percent"),
             do: config,
             else: default_percents()

        entry_price
        |> percent_result(fallback_config, direction)
        |> Map.put(:fallback_reason, reason)
    end
  end

  def resolve_levels(entry_price, %{"method" => "percent_of_entry"} = config, direction, _opts) do
    percent_result(entry_price, config, direction)
  end

  def resolve_levels(entry_price, _config, direction, _opts) do
    percent_result(entry_price, default_percents(), direction)
  end

  defp percent_result(entry_price, config, direction) do
    {stop_loss, take_profit} = percent_of_entry_levels(entry_price, config, direction)

    %{
      stop_loss: stop_loss,
      take_profit: take_profit,
      method: "percent_of_entry",
      daily_vol: nil,
      fallback_reason: nil
    }
  end

  defp default_percents do
    %{
      "stop_loss_percent" => Decimal.to_float(@default_stop_loss_percent) * 100,
      "take_profit_percent" => Decimal.to_float(@default_take_profit_percent) * 100
    }
  end

  defp vol_levels(entry_price, daily_vol, sl_mult, tp_mult, direction) do
    sl_distance = entry_price |> Decimal.mult(daily_vol) |> Decimal.mult(sl_mult)
    tp_distance = entry_price |> Decimal.mult(daily_vol) |> Decimal.mult(tp_mult)

    {stop_loss, take_profit} =
      case direction do
        "short" -> {Decimal.add(entry_price, sl_distance), Decimal.sub(entry_price, tp_distance)}
        _long -> {Decimal.sub(entry_price, sl_distance), Decimal.add(entry_price, tp_distance)}
      end

    # A long's stop, or a short's target, at or below zero is not a price.
    if Decimal.compare(stop_loss, 0) == :gt and Decimal.compare(take_profit, 0) == :gt do
      {:ok, stop_loss, take_profit}
    else
      {:error, :invalid_level}
    end
  end

  defp positive(value, reason) do
    case to_decimal(value) do
      {:ok, d} -> if Decimal.compare(d, 0) == :gt, do: {:ok, d}, else: {:error, reason}
      :error -> {:error, reason}
    end
  end

  defp to_decimal(%Decimal{} = d), do: {:ok, d}
  defp to_decimal(n) when is_integer(n), do: {:ok, Decimal.new(n)}
  defp to_decimal(n) when is_float(n), do: {:ok, Decimal.from_float(n)}

  defp to_decimal(s) when is_binary(s) do
    case Decimal.parse(s) do
      {d, ""} -> {:ok, d}
      _ -> :error
    end
  end

  defp to_decimal(_other), do: :error

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
