defmodule TradingCore.Signal.Spec do
  @moduledoc """
  Plain, serializable description of one signal to compute — the input to
  `TradingCore.Signal.Compute.init/1`/`replay/3`.

  This is a *description*, not a running computation: nothing here holds
  state or performs I/O. A `t()` is ordinary data (a struct of primitives,
  atoms, `Decimal`s, and nested `t()`s), so it can be built by hand, stored
  as a term or serialized to/from JSON by a caller (a persisted
  `SignalDefinition` row, a generated strategy variant, a backtest config),
  and compared for equality.

  ## Fields

    * `:kind` — which computation to run. One of `TradingCore.Signal.Compute`'s
      known kinds: `:plain`, `:derivative`, `:second_derivative`, `:wavelet`,
      `:volume`, `:vwap`, `:donchian`, `:rolling_volume`, `:self_zscore`,
      `:percent_deviation`, `:zscore`, `:regime`, `:ratio`.
    * `:symbol` — the underlying instrument this spec is ultimately scoped
      to, or `nil` for a spec whose only inputs are its `:parent`/
      `:reference` (every wrapping kind — see `TradingSignal.Signals.SignalDefinition`'s
      own `@base_kinds`/`@dual_parent_kinds`/`@single_parent_kinds` split,
      which this mirrors).
    * `:source` — which feed/provider this spec's raw ticks come from (e.g.
      `"ibkr"`, `"massive"`) — meaningful only for a base kind with its own
      `:symbol`; carried here so a caller building a spec tree from a
      `SignalDefinition` doesn't need a side-channel.
    * `:params` — kind-specific tuning knobs as a plain map with string
      keys (mirrors `SignalDefinition.params`'s own jsonb shape exactly, so
      a caller can pass a definition's `params` straight through
      unchanged). Recognized keys per kind are documented on the relevant
      `TradingCore.Signal.Compute` clause.
    * `:window_ms` — precomputed window duration in milliseconds, for kinds
      that need one and whose caller has already resolved a duration
      string (e.g. `params["window"]`) via its own parser
      (`TradingSignal.Signals.WindowMs.parse/2` today). Kept distinct from
      `:params` (rather than requiring `Compute` to parse a duration
      string itself) so this library never needs to know that string
      format at all — see `TradingCore.Signal.Compute`'s moduledoc.
    * `:expression` — reserved for a future `expression`-kind spec (the
      `TradingSignal.Signals.DefinitionSignal`/`Expression`
      formula-evaluation path). Not dispatched by any `Compute` kind today
      — see `TradingCore.Signals`'s own moduledoc, "What's deliberately
      NOT extracted here," for why that stays in `trading_signal`. Present
      here only so a spec tree built from a real `SignalDefinition` has
      somewhere to carry it without extra plumbing later.
    * `:parent` — the single wrapped spec, for a single-parent kind
      (`derivative`, `second_derivative`, `wavelet`, `self_zscore`,
      `rolling_volume`'s underlying reading source is `:symbol`-driven, not
      `:parent`-driven — see below) or the "value"/"direction" side of a
      dual-parent kind (`percent_deviation`, `zscore`, `ratio`, `regime`).
      `nil` for a base kind.
    * `:reference` — the "reference"/"gate" side of a dual-parent kind
      (`percent_deviation`, `zscore`, `ratio`, `regime` — mirrors
      `SignalDefinition.reference_parent_id`). `nil` for every other kind.

  ## Why `window_ms` is precomputed, not a duration string

  `trading_signal` stores window durations as human strings
  (`params["window"] == "20m"`) and parses them once, at `init_compute/1`
  time, via `TradingSignal.Signals.WindowMs.parse/2`. That parser (and its
  fallback-default behavior) is a `trading_signal`-level concern with no
  bearing on the actual windowing math, so rather than duplicate or
  re-import it here, every `Spec` simply carries the already-resolved
  millisecond value. A future `trading_backtest` caller building specs
  from its own config format can do the same — resolve a duration to
  milliseconds however it likes, then hand `Compute` a plain integer.

  ## Why `:parent`/`:reference` are nested `t()`s, not ids

  `TradingSignal.Signals.SignalDefinition`'s DAG is expressed as
  `parent_id`/`reference_parent_id` foreign keys into a database table —
  natural for a persisted, editable row, but this library has no `Repo`
  and no database (see `TradingCore.Signal.Compute`'s moduledoc, "No
  GenServer, no Ecto"). A caller that *does* have the database (or an
  equivalent id-indexed spec map) is expected to walk `parent_id`/
  `reference_parent_id` once and build the actual nested spec tree — at
  which point `TradingCore.Signal.Compute.replay/3` can resolve and
  evaluate it topologically without ever needing to look anything up
  again. This also means the same spec tree, once built, is what both a
  live driver and a replay/backtest caller feed to `Compute` — there is
  only one shape of "what is this signal made of."
  """

  @enforce_keys [:kind]
  defstruct kind: nil,
            symbol: nil,
            source: nil,
            params: %{},
            window_ms: nil,
            expression: nil,
            parent: nil,
            reference: nil

  @type kind ::
          :plain
          | :derivative
          | :second_derivative
          | :wavelet
          | :volume
          | :vwap
          | :donchian
          | :rolling_volume
          | :self_zscore
          | :percent_deviation
          | :zscore
          | :regime
          | :ratio

  @type t :: %__MODULE__{
          kind: kind(),
          symbol: String.t() | nil,
          source: String.t() | nil,
          params: %{optional(String.t()) => term()},
          window_ms: pos_integer() | nil,
          expression: String.t() | nil,
          parent: t() | nil,
          reference: t() | nil
        }

  # Mirrors TradingSignal.Signals.SignalDefinition's own @base_kinds:
  # these have no parent/reference at all — their raw input is a tick
  # keyed by :symbol/:source, supplied directly to Compute.step/2 by the
  # caller (Compute has no feed of its own to pull from).
  @base_kinds ~w(plain volume vwap donchian rolling_volume)a

  # Mirrors @single_parent_kinds: wrap exactly one parent's own value
  # stream over time.
  @single_parent_kinds ~w(derivative second_derivative wavelet self_zscore)a

  # Mirrors @dual_parent_kinds: compare a "value"/"direction" parent
  # against a separate "reference"/"gate" parent's current value.
  @dual_parent_kinds ~w(percent_deviation zscore regime ratio)a

  @doc "Every recognized `:kind` value."
  @spec kinds() :: [kind()]
  def kinds, do: @base_kinds ++ @single_parent_kinds ++ @dual_parent_kinds

  @doc "`true` for a kind with no `:parent`/`:reference` (its own symbol/source feed)."
  @spec base_kind?(kind()) :: boolean()
  def base_kind?(kind), do: kind in @base_kinds

  @doc "`true` for a kind wrapping exactly one `:parent`."
  @spec single_parent_kind?(kind()) :: boolean()
  def single_parent_kind?(kind), do: kind in @single_parent_kinds

  @doc "`true` for a kind comparing a `:parent` against a `:reference`."
  @spec dual_parent_kind?(kind()) :: boolean()
  def dual_parent_kind?(kind), do: kind in @dual_parent_kinds

  @doc """
  Every spec node reachable from `spec`, itself included — a flat list
  usable to walk the DAG without recursing by hand. Order is unspecified
  (callers that need topological order should use
  `TradingCore.Signal.Compute.replay/3`, which resolves this internally).
  """
  @spec nodes(t()) :: [t()]
  def nodes(%__MODULE__{} = spec) do
    parent_nodes = if spec.parent, do: nodes(spec.parent), else: []
    reference_nodes = if spec.reference, do: nodes(spec.reference), else: []
    [spec | parent_nodes ++ reference_nodes]
  end
end
