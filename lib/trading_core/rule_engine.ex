defmodule TradingCore.RuleEngine do
  @moduledoc """
  Evaluates a strategy version's `rules` jsonb (entry or exit condition tree)
  against a signal snapshot — a flat `%{"signal_name" => Decimal.t() | number()}`
  map the caller builds from whatever's on hand (a run's own stop/target
  prices, a live tick, a value pulled from a signal registry). This module
  only compares numbers already computed elsewhere; it never fetches
  anything itself, so it stays a pure function with no side effects and
  nothing to sandbox.

  Extracted from `TradingSystem.Trading.RuleEngine` into this shared
  library so `trading_system`'s paper simulator and `trading_live`'s live
  GenServers evaluate rule trees with byte-for-byte identical logic — this
  is what makes a strategy's quarantine results a trustworthy predictor of
  its live behavior. The API below must not diverge between callers.

  A condition node compares a named signal against either a fixed literal
  (`"value"`) or another named signal (`"value_signal"`) — the latter is
  what lets an exit rule express "current price crossed *this run's own*
  stop-loss price" without baking a specific number into the version's rule
  (stop_loss_price is fixed per-run at entry time, not a per-version
  constant, so the rule has to reference it by name).

  Naming convention: a name prefixed `run_` (`run_current_price`,
  `run_stop_loss_price`, `run_take_profit_price`) is a value the *caller*
  supplies from the run itself, not a real catalog signal. Anything without
  that prefix (`vix_last`, `momentum:SPY:5m`) is expected to resolve
  through a signal bus. This module itself doesn't enforce or care about
  the distinction — it just compares whatever's in the snapshot.

  Condition shape:

      %{"signal" => "run_current_price", "op" => "lte", "value_signal" => "run_stop_loss_price"}
      %{"signal" => "vix_last", "op" => "lt", "value" => 18}

  Combinator shape (recurse into `"conditions"`):

      %{"all" => [condition, condition, ...]}
      %{"any" => [condition, condition, ...]}
      %{"not" => condition}

  A missing signal in the snapshot fails closed (the condition is not met)
  — a rule referencing a signal nobody supplied should never be silently
  treated as satisfied.
  """

  @type snapshot :: %{optional(String.t()) => Decimal.t() | number()}
  @type rule :: map()

  @doc """
  `true` if `rule` is satisfied against `snapshot`. A `nil` or empty-map rule
  is vacuously satisfied (no condition to fail) — this is what lets a version
  with no `rules` configured fall back to "always true" at the entry side and
  rely on the caller's own fallback at the exit side.
  """
  @spec evaluate(rule() | nil, snapshot()) :: boolean()
  def evaluate(nil, _snapshot), do: true
  def evaluate(rule, _snapshot) when map_size(rule) == 0, do: true

  def evaluate(%{"all" => conditions}, snapshot) when is_list(conditions) do
    Enum.all?(conditions, &evaluate(&1, snapshot))
  end

  def evaluate(%{"any" => conditions}, snapshot) when is_list(conditions) do
    Enum.any?(conditions, &evaluate(&1, snapshot))
  end

  def evaluate(%{"not" => condition}, snapshot) when is_map(condition) do
    not evaluate(condition, snapshot)
  end

  def evaluate(%{"signal" => signal_name, "op" => op} = condition, snapshot) do
    with {:ok, left} <- fetch_signal(snapshot, signal_name),
         {:ok, right} <- fetch_comparand(condition, snapshot) do
      compare(op, left, right)
    else
      :error -> false
    end
  end

  def evaluate(_malformed, _snapshot), do: false

  @doc """
  How strongly `rule` passed against `snapshot`, as a `0.0..1.0` score —
  only meaningful for a rule that already `evaluate/2 == true`, this is
  "how far past the threshold" a passing rule cleared by, not a substitute
  for the boolean gate. Useful for deriving a synthesized confidence for an
  auto-opened run when there's no human supplying one.

  A leaf condition's margin is the relative distance `left` cleared `right`
  by, clamped to `[0.0, 1.0]` (a huge blowout doesn't mean "more confident"
  past 1.0 — it's a normalized score, not a raw distance). `"all"` combines
  by average (every leg matters equally), `"any"` by max (the single
  strongest passing leg carries it), `"not"` inverts. Same fail-closed
  convention as `evaluate/2`: a missing signal or malformed node scores
  `0.0`, not an error.
  """
  @spec margin(rule() | nil, snapshot()) :: float()
  def margin(nil, _snapshot), do: 1.0
  def margin(rule, _snapshot) when map_size(rule) == 0, do: 1.0

  def margin(%{"all" => conditions}, snapshot) when is_list(conditions) and conditions != [] do
    conditions
    |> Enum.map(&margin(&1, snapshot))
    |> then(&(Enum.sum(&1) / length(&1)))
  end

  def margin(%{"any" => conditions}, snapshot) when is_list(conditions) and conditions != [] do
    conditions |> Enum.map(&margin(&1, snapshot)) |> Enum.max()
  end

  def margin(%{"not" => condition}, snapshot) when is_map(condition) do
    1.0 - margin(condition, snapshot)
  end

  def margin(%{"signal" => signal_name, "op" => op} = condition, snapshot) do
    with {:ok, left} <- fetch_signal(snapshot, signal_name),
         {:ok, right} <- fetch_comparand(condition, snapshot) do
      leaf_margin(op, left, right)
    else
      :error -> 0.0
    end
  end

  def margin(_malformed, _snapshot), do: 0.0

  @doc """
  Every signal name a rule tree references, either as the left-hand
  `"signal"` or as a `"value_signal"` comparand — both need a value in the
  snapshot before `evaluate/2`/`margin/2` can evaluate them. Used to know
  which signals to request/subscribe to before a tick, and to display what
  a strategy is watching. `nil`/malformed input yields `[]`, same
  fail-closed spirit as `evaluate/2` — nothing to reference means nothing
  to collect.
  """
  @spec signal_names(rule() | nil) :: [String.t()]
  def signal_names(nil), do: []

  def signal_names(%{"all" => conditions}) when is_list(conditions),
    do: Enum.flat_map(conditions, &signal_names/1)

  def signal_names(%{"any" => conditions}) when is_list(conditions),
    do: Enum.flat_map(conditions, &signal_names/1)

  def signal_names(%{"not" => condition}) when is_map(condition),
    do: signal_names(condition)

  def signal_names(%{"signal" => name} = condition) do
    case condition do
      %{"value_signal" => other_name} -> [name, other_name]
      _ -> [name]
    end
  end

  def signal_names(_other), do: []

  defp leaf_margin(op, left, right) when op in ["gt", "gte", "lt", "lte"] do
    denominator = right |> Decimal.abs() |> Decimal.max(Decimal.new("0.0001"))

    left
    |> Decimal.sub(right)
    |> Decimal.abs()
    |> Decimal.div(denominator)
    |> Decimal.to_float()
    |> min(1.0)
    |> max(0.0)
  end

  defp leaf_margin("eq", left, right), do: if(Decimal.equal?(left, right), do: 1.0, else: 0.0)
  defp leaf_margin(_unrecognized_op, _left, _right), do: 0.0

  defp fetch_comparand(%{"value_signal" => signal_name}, snapshot),
    do: fetch_signal(snapshot, signal_name)

  defp fetch_comparand(%{"value" => value}, _snapshot), do: {:ok, to_decimal(value)}
  defp fetch_comparand(_condition, _snapshot), do: :error

  defp fetch_signal(snapshot, signal_name) do
    case Map.fetch(snapshot, signal_name) do
      {:ok, value} -> {:ok, to_decimal(value)}
      :error -> :error
    end
  end

  defp compare("gt", left, right), do: Decimal.compare(left, right) == :gt
  defp compare("gte", left, right), do: Decimal.compare(left, right) != :lt
  defp compare("lt", left, right), do: Decimal.compare(left, right) == :lt
  defp compare("lte", left, right), do: Decimal.compare(left, right) != :gt
  defp compare("eq", left, right), do: Decimal.compare(left, right) == :eq
  defp compare(_unrecognized_op, _left, _right), do: false

  defp to_decimal(%Decimal{} = value), do: value
  defp to_decimal(value) when is_float(value), do: Decimal.from_float(value)
  defp to_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp to_decimal(value) when is_binary(value), do: Decimal.new(value)
end
