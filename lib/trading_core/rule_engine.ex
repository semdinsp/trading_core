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

  ## Operators

  Stateless threshold tests: `gt`, `gte`, `lt`, `lte`, `eq` and `ne`
  (not equal: "exit when the regime is no longer -1"). Transition tests:
  `crosses_above`, `crosses_below`, `sign_flip`, `changed` (below).
  `known_ops/0` lists them all. An op not in that list never matches at
  evaluation time (it is unknown, so it fails closed even under
  `"not"`); `validate/1` reports it so a caller can reject the rule when
  it is saved instead.

  A missing signal in the snapshot fails closed (the condition is not met)
  — a rule referencing a signal nobody supplied should never be silently
  treated as satisfied. A key present with a `nil` value counts as
  missing: a signal bus that emits `nil` while warming up produces the
  same "no value to compare" state as an absent key, and both decline the
  condition rather than raising.

  ## Transition operators and the `prev_` convention

  `gt`/`gte`/`lt`/`lte`/`eq`/`ne` are stateless threshold tests: they ask "is
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

  A transition leg has **no margin** — it fired or it didn't, with no
  "how far past the threshold" reading — so `margin_or_nil/2` excludes
  such legs rather than scoring them. See that function's own doc.

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

  @stateless_ops ["gt", "gte", "lt", "lte", "eq", "ne"]

  # The subset of the above that still take a threshold comparand;
  # `sign_flip`/`changed` carry no "value"/"value_signal".
  @thresholded_transition_ops ["crosses_above", "crosses_below"]

  @doc "Every operator `evaluate/2` recognizes: `comparison_ops/0` then `transition_ops/0`."
  @spec known_ops() :: [String.t()]
  def known_ops, do: @stateless_ops ++ @transition_ops

  @doc "The stateless threshold operators: `gt`, `gte`, `lt`, `lte`, `eq`, `ne`."
  @spec comparison_ops() :: [String.t()]
  def comparison_ops, do: @stateless_ops

  @doc """
  The transition operators, which also read `prev_<signal>` from the
  snapshot. A caller that never supplies `prev_` values can use this to
  reject them in its own rules.
  """
  @spec transition_ops() :: [String.t()]
  def transition_ops, do: @transition_ops

  @typedoc "Where in a rule tree a problem is: map keys and list indices from the root."
  @type path :: [String.t() | non_neg_integer()]

  @type validation_error ::
          :unknown_op
          | :missing_op
          | :missing_signal
          | :missing_value
          | :non_numeric_value
          | :invalid_value_signal
          | :invalid_conditions
          | :empty_any
          | :transition_op_not_allowed
          | :invalid_not
          | :malformed_node

  @doc """
  Checks a rule tree's shape without evaluating it, so a caller can reject
  a bad rule when it is saved rather than discover weeks later that it
  never fires. Walks `"all"`/`"any"`/`"not"` and checks every leaf:

    * `:missing_signal`: no non-empty `"signal"` string.
    * `:missing_op` / `:unknown_op`: no `"op"`, or one not in `known_ops/0`
      (e.g. `"neq"`, `"!="`).
    * `:missing_value`: a stateless op or `crosses_above`/`crosses_below`
      with neither `"value"` nor `"value_signal"` (or `"value" => nil`).
      `sign_flip`/`changed` take no comparand.
    * `:non_numeric_value`: a `"value"` that isn't a number, a `Decimal`
      or a numeric string.
    * `:invalid_value_signal`: a `"value_signal"` that isn't a non-empty
      string.
    * `:invalid_conditions` / `:invalid_not`: `"all"`/`"any"` not a list,
      `"not"` not a map.
    * `:empty_any`: `"any": []`, which can never pass. (`"all": []` is
      vacuously true and accepted.)
    * `:transition_op_not_allowed`: a transition op when
      `allow_transition_ops: false`. Transition ops read `prev_<signal>`,
      so they only fire where the caller supplies it; an entry path that
      never does would evaluate them as unknown on every tick. The option
      defaults to `true`.
    * `:malformed_node`: a node with none of `"all"`, `"any"`, `"not"`,
      `"signal"`.

  `nil` and `%{}` are valid at any depth (vacuously true). It accepts
  everything `evaluate/2` can evaluate and is no stricter. Returns `:ok` or
  `{:error, [{path, reason}]}` in tree order, where `path` is the keys and
  list indices from the root, e.g. `["all", 1, "not"]`.

  This only reports. Evaluation is unchanged: anything flagged here is
  still evaluated as unknown, i.e. it fails closed. `format_errors/1`
  turns the result into messages; `validate_rules/1` checks an
  `%{"entry" => ..., "exit" => ...}` pair.
  """
  @spec validate(rule() | nil, keyword()) :: :ok | {:error, [{path(), validation_error()}]}
  def validate(rule, opts \\ []) do
    case validate_node(rule, [], opts) do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  @doc """
  `validate/2` over a strategy's `%{"entry" => rule, "exit" => rule}`,
  with each path prefixed by `"entry"` or `"exit"`. A missing side is
  treated as `nil` (valid). `opts[:entry]` and `opts[:exit]` are the
  `validate/2` options for each side, e.g.
  `validate_rules(rules, entry: [allow_transition_ops: false])` for a
  caller whose entry path never supplies `prev_` values.
  """
  @spec validate_rules(map(), keyword()) :: :ok | {:error, [{path(), validation_error()}]}
  def validate_rules(rules, opts \\ []) when is_map(rules) do
    errors =
      Enum.flat_map([entry: "entry", exit: "exit"], fn {side, key} ->
        validate_node(Map.get(rules, key), [key], Keyword.get(opts, side, []))
      end)

    if errors == [], do: :ok, else: {:error, errors}
  end

  @doc """
  Human-readable messages for `validate/1`'s errors, e.g.
  `"entry.all[1].not.op: unknown op \"neq\" (use \"ne\")"`. Takes the
  error list or the whole `{:error, list}` result; `:ok` gives `[]`.
  """
  @spec format_errors(:ok | {:error, list()} | list()) :: [String.t()]
  def format_errors(:ok), do: []
  def format_errors({:error, errors}), do: format_errors(errors)

  def format_errors(errors) when is_list(errors),
    do: Enum.map(errors, fn {path, reason} -> "#{format_path(path)}: #{describe(reason)}" end)

  defp format_path([]), do: "rule"

  defp format_path(path) do
    path
    |> Enum.map(fn
      i when is_integer(i) -> "[#{i}]"
      key -> "." <> key
    end)
    |> Enum.join()
    |> String.trim_leading(".")
  end

  defp describe(:unknown_op),
    do: "unknown op (supported: #{Enum.join(@stateless_ops ++ @transition_ops, ", ")})"

  defp describe(:missing_op), do: "missing \"op\""
  defp describe(:missing_signal), do: "missing \"signal\""
  defp describe(:missing_value), do: "needs a \"value\" or \"value_signal\""
  defp describe(:non_numeric_value), do: "\"value\" must be a number or numeric string"
  defp describe(:invalid_value_signal), do: "\"value_signal\" must be a signal name"
  defp describe(:invalid_conditions), do: "must be a list of conditions"
  defp describe(:empty_any), do: "an empty \"any\" can never pass"

  defp describe(:transition_op_not_allowed),
    do:
      "transition ops (#{Enum.join(@transition_ops, ", ")}) need prev_ values this path doesn't supply"

  defp describe(:invalid_not), do: "\"not\" must wrap a single condition"
  defp describe(:malformed_node), do: "not a condition (expects all/any/not or signal/op)"

  defp validate_node(nil, _path, _opts), do: []
  defp validate_node(rule, _path, _opts) when rule == %{}, do: []

  defp validate_node(%{"all" => conditions}, path, opts),
    do: validate_list("all", conditions, path, opts)

  defp validate_node(%{"any" => conditions}, path, opts),
    do: validate_list("any", conditions, path, opts)

  defp validate_node(%{"not" => condition}, path, opts) when is_map(condition),
    do: validate_node(condition, path ++ ["not"], opts)

  defp validate_node(%{"not" => _other}, path, _opts), do: [{path ++ ["not"], :invalid_not}]

  defp validate_node(%{"signal" => _} = leaf, path, opts), do: validate_leaf(leaf, path, opts)
  defp validate_node(%{"op" => _} = leaf, path, opts), do: validate_leaf(leaf, path, opts)

  defp validate_node(_malformed, path, _opts), do: [{path, :malformed_node}]

  defp validate_list("any", [], path, _opts), do: [{path ++ ["any"], :empty_any}]

  defp validate_list(key, conditions, path, opts) when is_list(conditions) do
    conditions
    |> Enum.with_index()
    |> Enum.flat_map(fn {condition, i} -> validate_node(condition, path ++ [key, i], opts) end)
  end

  defp validate_list(key, _conditions, path, _opts), do: [{path ++ [key], :invalid_conditions}]

  defp validate_leaf(leaf, path, opts) do
    signal_errors =
      case Map.get(leaf, "signal") do
        name when is_binary(name) and name != "" -> []
        _ -> [{path ++ ["signal"], :missing_signal}]
      end

    op = Map.get(leaf, "op")

    op_errors =
      cond do
        is_nil(op) ->
          [{path ++ ["op"], :missing_op}]

        op in @transition_ops and not Keyword.get(opts, :allow_transition_ops, true) ->
          [{path ++ ["op"], :transition_op_not_allowed}]

        op in @stateless_ops or op in @transition_ops ->
          []

        true ->
          [{path ++ ["op"], :unknown_op}]
      end

    comparand_errors =
      if op in @stateless_ops or op in @thresholded_transition_ops,
        do: validate_comparand(leaf, path),
        else: []

    signal_errors ++ op_errors ++ comparand_errors
  end

  defp validate_comparand(%{"value_signal" => name}, _path) when is_binary(name) and name != "",
    do: []

  defp validate_comparand(%{"value_signal" => _}, path),
    do: [{path ++ ["value_signal"], :invalid_value_signal}]

  defp validate_comparand(%{"value" => value}, path) when not is_nil(value) do
    if numeric?(value), do: [], else: [{path ++ ["value"], :non_numeric_value}]
  end

  defp validate_comparand(_leaf, path), do: [{path ++ ["value"], :missing_value}]

  defp numeric?(value) when is_number(value), do: true
  defp numeric?(%Decimal{} = value), do: not (Decimal.nan?(value) or Decimal.inf?(value))

  defp numeric?(value) when is_binary(value) do
    case Decimal.parse(String.trim(value)) do
      {d, ""} -> numeric?(d)
      _ -> false
    end
  end

  defp numeric?(_value), do: false

  @doc """
  `true` if `rule` is satisfied against `snapshot`. A `nil` or empty-map rule
  is vacuously satisfied (no condition to fail) — this is what lets a version
  with no `rules` configured fall back to "always true" at the entry side and
  rely on the caller's own fallback at the exit side.

  A condition that reads a signal missing from `snapshot` (including a
  `"value_signal"` comparand or a transition op's `prev_<signal>`) has no
  determinable truth. Internally it is *unknown*, not false, and unknown
  propagates through the combinators with three-valued (Kleene) logic:

    * `"not"` of unknown is unknown — so negating a condition over absent
      data does **not** pass. `{"not": {"signal": "x", "op": "gt", ...}}`
      is `false` when `x` is missing, not `true`.
    * `"all"` is false if any leg is false, else unknown if any leg is
      unknown, else true.
    * `"any"` is true if any leg is true, else unknown if any leg is
      unknown, else false.

  Only the final answer collapses unknown to `false`. Without `"not"` this
  is indistinguishable from treating a missing leaf as `false`; the
  distinction only matters under a negation, which would otherwise turn
  "no data" into a pass. A malformed node is likewise unknown, so it fails
  closed under `"not"` too. `margin_or_nil/2` gives `nil` (no margin) for
  a `"not"` whose condition is unknown here, rather than inverting it.
  """
  @spec evaluate(rule() | nil, snapshot()) :: boolean()
  def evaluate(rule, snapshot), do: eval3(rule, snapshot) == true

  # Three-valued evaluation: `true | false | :unknown`. See evaluate/2's doc.
  defp eval3(nil, _snapshot), do: true
  defp eval3(rule, _snapshot) when map_size(rule) == 0, do: true

  defp eval3(%{"all" => conditions}, snapshot) when is_list(conditions) do
    Enum.reduce_while(conditions, true, fn condition, acc ->
      case eval3(condition, snapshot) do
        false -> {:halt, false}
        :unknown -> {:cont, :unknown}
        true -> {:cont, acc}
      end
    end)
  end

  defp eval3(%{"any" => conditions}, snapshot) when is_list(conditions) do
    Enum.reduce_while(conditions, false, fn condition, acc ->
      case eval3(condition, snapshot) do
        true -> {:halt, true}
        :unknown -> {:cont, :unknown}
        false -> {:cont, acc}
      end
    end)
  end

  defp eval3(%{"not" => condition}, snapshot) when is_map(condition) do
    case eval3(condition, snapshot) do
      :unknown -> :unknown
      value -> not value
    end
  end

  # Transition operators need both edges (the prior value as well as the
  # current one), so they fetch `prev_<signal>` alongside `<signal>`
  # rather than a comparand-vs-level pair. Matched ahead of the general
  # leaf clause below; the stateless ops never reach here, so their
  # behavior is bit-identical to before this clause existed.
  defp eval3(%{"signal" => signal_name, "op" => op} = condition, snapshot)
       when op in @transition_ops do
    with {:ok, now} <- fetch_signal(snapshot, signal_name),
         {:ok, prev} <- fetch_signal(snapshot, prev_key(signal_name)),
         {:ok, threshold} <- fetch_transition_comparand(op, condition, snapshot) do
      transition(op, prev, now, threshold)
    else
      :error -> :unknown
    end
  end

  defp eval3(%{"signal" => signal_name, "op" => op} = condition, snapshot) do
    with {:ok, left} <- fetch_signal(snapshot, signal_name),
         {:ok, right} <- fetch_comparand(condition, snapshot) do
      compare(op, left, right)
    else
      :error -> :unknown
    end
  end

  defp eval3(_malformed, _snapshot), do: :unknown

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

  **Transition legs have no margin at all** and are excluded rather than
  scored — see `margin_or_nil/2`, which this function delegates to. A rule
  with no measurable leg (every leg a transition op) has no margin to
  report; this function answers `1.0` for that case, matching how it
  already treats a `nil`/empty rule — "nothing constrains this" — and
  keeping the `float()` return a caller like `trading_system`'s
  `EntryEvaluator.enqueue_entry` can store directly as a confidence. A
  caller that needs to tell "no measurable margin" apart from "measured,
  and it cleared comfortably" must call `margin_or_nil/2` instead.
  """
  @spec margin(rule() | nil, snapshot()) :: float()
  def margin(rule, snapshot) do
    case margin_or_nil(rule, snapshot) do
      nil -> 1.0
      value -> value
    end
  end

  @doc """
  Like `margin/2`, but returns `nil` where no margin is meaningful rather
  than substituting a number.

  Margin measures *how far past a threshold* a passing leg cleared. A
  transition operator (`crosses_above`, `crosses_below`, `sign_flip`,
  `changed`) has no such reading — it either fired on this step or it
  didn't — so scoring it `1.0`/`0.0` would smuggle a boolean into a
  continuous statistic. Averaged across runs that produces a *fire rate*
  wearing the name "mean margin", which is a different number than it
  appears to be. Such legs are therefore absent, not zero and not one.

  Absence propagates through the combinators:

    * `"all"` averages **only the legs that have a margin** — a transition
      leg is not in the numerator or the denominator, so an `all` of
      `[threshold, transition]` scores exactly what the threshold leg
      scored. All legs absent ⇒ `nil`.
    * `"any"` takes the max **over the legs that have a margin**. All legs
      absent ⇒ `nil`.
    * `"not"` inverts a present margin (`1.0 - m`) and **propagates
      absence** — the inverse of "no meaningful margin" is still no
      meaningful margin, not `1.0 - nil`. Inverting an absent value would
      invent a reading the underlying leg never produced.
    * `"not"` over a condition `evaluate/2` can't determine (it reads a
      missing signal, or is malformed) is also `nil`. A missing leaf
      scores `0.0`, so inverting it would give a full `1.0` margin from no
      data, and an `"any"` would then report that `1.0` over a real
      passing leg's smaller margin.

  A rule whose legs are all transitions therefore yields `nil` — "margin
  is not a meaningful question for this rule" — rather than a fire rate.

  This is deliberately *not* the same question as `evaluate/2`: a leg can
  be absent here while still being decisive there. `evaluate/2` is
  unaffected by any of this.
  """
  @spec margin_or_nil(rule() | nil, snapshot()) :: float() | nil
  def margin_or_nil(nil, _snapshot), do: 1.0
  def margin_or_nil(rule, _snapshot) when map_size(rule) == 0, do: 1.0

  def margin_or_nil(%{"all" => conditions}, snapshot)
      when is_list(conditions) and conditions != [] do
    conditions
    |> Enum.map(&margin_or_nil(&1, snapshot))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      measurable -> Enum.sum(measurable) / length(measurable)
    end
  end

  def margin_or_nil(%{"any" => conditions}, snapshot)
      when is_list(conditions) and conditions != [] do
    conditions
    |> Enum.map(&margin_or_nil(&1, snapshot))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      measurable -> Enum.max(measurable)
    end
  end

  def margin_or_nil(%{"not" => condition}, snapshot) when is_map(condition) do
    if eval3(condition, snapshot) == :unknown do
      nil
    else
      case margin_or_nil(condition, snapshot) do
        nil -> nil
        value -> 1.0 - value
      end
    end
  end

  # A transition op reports no margin at all — see this function's own
  # doc. Matched ahead of the general leaf clause so these never reach
  # leaf_margin/3 (where they would otherwise hit the unrecognized-op
  # catch-all and score a misleading 0.0).
  def margin_or_nil(%{"signal" => _signal_name, "op" => op}, _snapshot)
      when op in @transition_ops,
      do: nil

  def margin_or_nil(%{"signal" => signal_name, "op" => op} = condition, snapshot) do
    with {:ok, left} <- fetch_signal(snapshot, signal_name),
         {:ok, right} <- fetch_comparand(condition, snapshot) do
      leaf_margin(op, left, right)
    else
      :error -> 0.0
    end
  end

  def margin_or_nil(_malformed, _snapshot), do: 0.0

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
  # Like "eq", a pass/fail with no distance to measure.
  defp leaf_margin("ne", left, right), do: if(Decimal.equal?(left, right), do: 0.0, else: 1.0)
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

  # A rule literal of `"value" => nil` is malformed JSON for a comparison,
  # not a comparable zero — same fail-closed answer as a missing key.
  defp fetch_comparand(%{"value" => nil}, _snapshot), do: :error
  # A non-numeric string literal ("abc") is malformed, not a crash:
  # Decimal.new/1 would raise inside a live exit sweep. validate/1 flags it.
  defp fetch_comparand(%{"value" => value}, _snapshot) when is_binary(value) do
    case Decimal.parse(String.trim(value)) do
      {d, ""} -> {:ok, d}
      _ -> :error
    end
  end

  defp fetch_comparand(%{"value" => value}, _snapshot), do: {:ok, to_decimal(value)}
  defp fetch_comparand(_condition, _snapshot), do: :error

  # A key present with a `nil` value is treated exactly as an absent key:
  # `:error`, so the condition fails closed.
  #
  # `@type snapshot` says `Decimal.t() | number()`, so a `nil` is strictly
  # a caller contract violation — but this clause is deliberate rather
  # than permissive. Without it `to_decimal/1` has no matching clause and
  # raises `FunctionClauseError` from inside whatever is evaluating, which
  # for the live callers is a periodic exit sweep: one unlucky snapshot
  # would abort the whole sweep, taking every *other* position's exit
  # check down with it, rather than declining one condition. "A missing
  # signal fails closed" (this module's own moduledoc) is the intended
  # posture, and a nil is a missing signal by any useful reading.
  #
  # Known reachable shape: a signal bus that emits `nil` while warming up.
  # `trading_system`'s exit path happens to omit the key entirely in that
  # case (verified), but that is one caller's convention, not something
  # this shared module can rely on.
  defp fetch_signal(snapshot, signal_name) do
    case Map.fetch(snapshot, signal_name) do
      {:ok, nil} -> :error
      {:ok, value} -> {:ok, to_decimal(value)}
      :error -> :error
    end
  end

  defp compare("gt", left, right), do: Decimal.compare(left, right) == :gt
  defp compare("gte", left, right), do: Decimal.compare(left, right) != :lt
  defp compare("lt", left, right), do: Decimal.compare(left, right) == :lt
  defp compare("lte", left, right), do: Decimal.compare(left, right) != :gt
  defp compare("eq", left, right), do: Decimal.compare(left, right) == :eq
  defp compare("ne", left, right), do: Decimal.compare(left, right) != :eq
  # Unknown rather than false, so a typo'd op fails closed under "not" too.
  defp compare(_unrecognized_op, _left, _right), do: :unknown

  defp to_decimal(%Decimal{} = value), do: value
  defp to_decimal(value) when is_float(value), do: Decimal.from_float(value)
  defp to_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp to_decimal(value) when is_binary(value), do: Decimal.new(value)
end
