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
  through a signal bus. A second caller-supplied convention exists
  alongside `run_`: a name prefixed `regime_` (e.g.
  `regime_trend_ordinal`, `regime_vol_ordinal`, as used by
  `trading_system`'s `EntryEvaluator`/`PositionExitCheck`) is a numeric
  regime classification the caller derived elsewhere — not a
  `SignalBus`/catalog signal, and not a per-run value either. This module
  itself doesn't enforce or care about any of these distinctions — it
  just compares whatever's in the snapshot.

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

  ## Transition operators and the `prev_` convention

  `gt`/`gte`/`lt`/`lte`/`eq` are stateless threshold tests: they ask "is
  signal X past threshold T *right now*". A signal jittering around T
  therefore flips true/false/true/false across consecutive evaluations,
  and every `true` is a real trigger. On the exit side that is whipsaw —
  the same position churning on noise, paying real slippage and
  commission each time.

  The four **transition operators** — `crosses_above`, `crosses_below`,
  `sign_flip`, `changed` — fire on a *change between evaluations* rather
  than on a level, which makes them scale-free: no per-signal deadband
  constant to hand-tune, and nothing that has to mean the same thing
  across a wavelet derivative and a composite.

  | op | fires when | comparand |
  |---|---|---|
  | `crosses_above` | `prev <= T` and `now > T` | `value` or `value_signal` |
  | `crosses_below` | `prev >= T` and `now < T` | `value` or `value_signal` |
  | `sign_flip` | `sign(prev) != sign(now)`, neither being zero | none |
  | `changed` | `prev != now` | none |

  `sign_flip` and `changed` take no comparand — a condition using them
  carries no `"value"`/`"value_signal"` key.

  A third caller-supplied naming convention carries the prior value: for
  a condition on signal `X`, the previous evaluation's value is read from
  `"prev_" <> X`. So `%{"signal" => "wavelet_deriv", "op" =>
  "crosses_above", "value" => 0}` reads both `"wavelet_deriv"` and
  `"prev_wavelet_deriv"` from the snapshot. This keeps the engine pure —
  it holds no state between calls and owns no ETS/process; the caller
  supplies both edges of the transition, exactly as it already supplies
  `run_`/`regime_` values.

  `signal_names/1` deliberately does **not** return `prev_` names — only
  the bare `X`. Callers use that list to decide which signals to resolve
  from a signal bus, and `prev_X` is not a catalog signal; returning it
  would make the caller try (and fail) to fetch it. Deriving the `prev_`
  key is the caller's job.

  A missing `prev_` key fails closed, same as any other missing signal.
  That is what makes the first evaluation after entry safe: with no prior
  value seeded, no transition fires on tick one, so a position that opens
  already past `T` does not instantly exit.

  ### Zero and `sign_flip`

  An exact zero on **either** side does not fire `sign_flip`. Zero is
  treated as "no sign" rather than as a sign of its own, so `+ → 0 → -`
  is a single flip observed on the `0 → -` step, not two. The reason is
  the whipsaw this operator exists to prevent: a signal resting at `0.0`
  and wobbling a hair either side would otherwise emit a flip on nearly
  every tick — precisely the churn the transition operators are meant to
  suppress. Use `changed` if a move off zero should itself be a trigger.
  """

  @type snapshot :: %{optional(String.t()) => Decimal.t() | number()}
  @type rule :: map()

  # Ops that compare the current value against the prior evaluation's
  # (read from `prev_<signal>`) rather than against a threshold alone.
  @transition_ops ["crosses_above", "crosses_below", "sign_flip", "changed"]

  # The subset of the above that still take a threshold comparand;
  # `sign_flip`/`changed` carry no "value"/"value_signal".
  @thresholded_transition_ops ["crosses_above", "crosses_below"]

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

  # Transition operators need both edges (the prior value as well as the
  # current one), so they fetch `prev_<signal>` alongside `<signal>`
  # rather than a comparand-vs-level pair. Matched ahead of the general
  # leaf clause below; the stateless ops never reach here, so their
  # behavior is bit-identical to before this clause existed.
  def evaluate(%{"signal" => signal_name, "op" => op} = condition, snapshot)
      when op in @transition_ops do
    with {:ok, now} <- fetch_signal(snapshot, signal_name),
         {:ok, prev} <- fetch_signal(snapshot, prev_key(signal_name)),
         {:ok, threshold} <- fetch_transition_comparand(op, condition, snapshot) do
      transition(op, prev, now, threshold)
    else
      :error -> false
    end
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

  # A transition op has no continuous "how far past the threshold"
  # reading to report — it either fired on this step or it didn't — so
  # its margin is the boolean restated as 1.0/0.0. Routed through
  # evaluate/2 rather than falling into leaf_margin/3's catch-all, both
  # so the two can never disagree and so this is a deliberate answer
  # rather than an accidental "unrecognized op scores 0.0".
  #
  # Note for consumers that average margins (trading_system's
  # ConditionStats.avg_margin) or store one as a confidence
  # (EntryEvaluator's enqueue_entry): averaging a binary yields a
  # fire-rate, not a mean margin. That is a different statistic under the
  # same name, so a rule mixing transition and threshold legs produces a
  # blended number worth reading with care.
  def margin(%{"signal" => _signal_name, "op" => op} = condition, snapshot)
      when op in @transition_ops do
    if evaluate(condition, snapshot), do: 1.0, else: 0.0
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

  Returns **bare names only, never the `prev_` keys** a transition
  operator also reads (see this module's own moduledoc). This is a
  contract, not an oversight: callers feed this list to a signal bus to
  resolve catalog signals, and `prev_X` is not one — it is a value the
  caller itself carries forward between evaluations. Adding `prev_`
  names here would make a caller try to fetch a signal that cannot
  resolve, and callers that require every returned name to be present in
  a snapshot (e.g. `trading_system`'s `ConditionStats`) would start
  silently excluding rows. A caller that needs the prior value derives
  the key itself.
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

  @doc """
  `true` if the rule tree references either regime pseudo-signal
  (`regime_trend_ordinal`/`regime_vol_ordinal`) anywhere, including nested
  inside "all"/"any"/"not". Built on `signal_names/1` rather than a new
  tree-walk, so this can never disagree with what `signal_names/1` already
  extracts.
  """
  @spec regime_condition?(map() | nil) :: boolean()
  def regime_condition?(rules) do
    rules
    |> signal_names()
    |> Enum.any?(&(&1 in ["regime_trend_ordinal", "regime_vol_ordinal"]))
  end

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

  # The snapshot key carrying `signal_name`'s value from the previous
  # evaluation. Deliberately not exposed via signal_names/1 — see this
  # module's own moduledoc for why the caller derives this itself.
  defp prev_key(signal_name), do: "prev_" <> signal_name

  # crosses_above/crosses_below compare against a threshold, so they
  # reuse the normal comparand path (literal or another signal).
  # sign_flip/changed have no comparand at all; {:ok, nil} keeps the
  # `with` in evaluate/2 uniform across all four.
  defp fetch_transition_comparand(op, condition, snapshot)
       when op in @thresholded_transition_ops,
       do: fetch_comparand(condition, snapshot)

  defp fetch_transition_comparand(_op, _condition, _snapshot), do: {:ok, nil}

  defp transition("crosses_above", prev, now, threshold) do
    Decimal.compare(prev, threshold) != :gt and Decimal.compare(now, threshold) == :gt
  end

  defp transition("crosses_below", prev, now, threshold) do
    Decimal.compare(prev, threshold) != :lt and Decimal.compare(now, threshold) == :lt
  end

  # Zero on either side is "no sign", not a sign of its own — so + -> 0 -> -
  # is one flip (on the 0 -> - step), not two, and a signal resting at
  # 0.0 doesn't emit a flip every tick it wobbles. See this module's own
  # moduledoc for the reasoning.
  defp transition("sign_flip", prev, now, _threshold) do
    prev_sign = sign_of(prev)
    now_sign = sign_of(now)

    prev_sign != 0 and now_sign != 0 and prev_sign != now_sign
  end

  defp transition("changed", prev, now, _threshold), do: not Decimal.equal?(prev, now)

  defp sign_of(value) do
    case Decimal.compare(value, Decimal.new(0)) do
      :gt -> 1
      :lt -> -1
      :eq -> 0
    end
  end

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
