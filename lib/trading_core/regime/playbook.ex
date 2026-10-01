defmodule TradingCore.Regime.Playbook do
  @moduledoc """
  The regime playbook: given a set of rules, one strategy, and the current
  regime label (`"vol|trend"`, as produced by `TradingCore.Regime.label/2`),
  decides whether that strategy may open a new position and at what size
  multiplier.

  Pure — rules, strategy context and label in, decision out. The caller
  (trading_live today, trading_system's paper/backtest runs later) owns the
  rule table, the label cache and any staleness check.

  ## Labels only, never raw VIX

  This module takes a label string, never a VIX level, and does no
  classification of its own. The live label comes from trading_signal,
  whose vol bands are `{16.0, 19.0}` (`TradingSignal.Regime.VolBands`) —
  **not** `TradingCore.Regime.default_vol_bands/0`'s `{15, 22}`. A
  backtest or trading_system consumer that builds its own labels must
  classify with trading_signal's bands, or the same rules will fire on
  different sessions than they do live.

  ## Resolution: most specific rule wins, no multiplication

  Only enabled rules whose selector matches the strategy and whose
  `vol_state`/`trend_state` match the label (`:any` matches anything) are
  considered. Of those, exactly one decides, ranked by:

  1. selector — `{:strategy_id, _}` (4) > `{:tag, _}` (3) >
     `{:exposure, _}` (2) > `:all` (1);
  2. label specificity — both axes exact (2) > one exact (1) > `:any|:any` (0);
  3. `priority` — higher wins;
  4. rule `id` — lexically smallest wins.

  The selector always dominates: a strategy-specific `:any|:any` rule beats
  an `:all` rule written for the exact cell. Multipliers are never
  combined — "stressed and chop" is its own `stressed|chop` rule.

  ## Nil or unparseable label

  A `nil` label, or one `TradingCore.Regime.parse_label/1` rejects (it
  returns a bare `:error`), resolves to `opts[:nil_regime]` and is reported
  with rule id `:nil_regime`. This never raises. The caller decides what
  counts as stale (e.g. a label from a previous session) and passes `nil`
  in that case.

  ## Options

  - `:nil_regime` — `:block | {:allow, multiplier}`, default `:block`
    (fail closed).
  - `:default` — `:block | {:allow, multiplier}` when no enabled rule
    matches, default `{:allow, Decimal.new(1)}`: rules restrict, so a
    strategy no rule mentions trades at full size. Pass `:block` to make
    the playbook an allow-list.
  """

  alias TradingCore.Regime

  @type vol :: :calm | :normal | :stressed
  @type trend :: :up | :chop | :down
  @type exposure :: :long_market | :short_market | :flat

  @type selector ::
          {:strategy_id, String.t()}
          | {:tag, String.t()}
          | {:exposure, :long_market | :short_market}
          | :all

  @type rule :: %{
          id: String.t(),
          vol_state: vol() | :any,
          trend_state: trend() | :any,
          selector: selector(),
          action: :allow | :block,
          size_multiplier: Decimal.t() | nil,
          priority: integer(),
          enabled: boolean()
        }

  @type strategy_ctx :: %{strategy_id: String.t(), tags: [String.t()], exposure: exposure()}

  @type source :: String.t() | :default | :nil_regime
  @type decision :: {:allow, Decimal.t(), source()} | {:block, source()}
  @type fallback :: :block | {:allow, Decimal.t()}

  @vol_states [:calm, :normal, :stressed]
  @trend_states [:up, :chop, :down]

  @doc """
  Decides `strategy_ctx`'s entry permission under `label`. See the
  moduledoc for resolution order and options.
  """
  @spec evaluate([rule()], strategy_ctx(), String.t() | nil, keyword()) :: decision()
  def evaluate(rules, strategy_ctx, label, opts \\ []) do
    case parse(label) do
      {:ok, cell} -> evaluate_cell(rules, strategy_ctx, cell, opts)
      :error -> fallback(Keyword.get(opts, :nil_regime, :block), :nil_regime)
    end
  end

  @doc """
  `evaluate/4` for all nine `{vol, trend}` cells — for the `/allocation`
  grid and an MCP preview.
  """
  @spec grid([rule()], strategy_ctx(), keyword()) :: %{{vol(), trend()} => decision()}
  def grid(rules, strategy_ctx, opts \\ []) do
    for vol <- @vol_states, trend <- @trend_states, into: %{} do
      {{vol, trend}, evaluate_cell(rules, strategy_ctx, {vol, trend}, opts)}
    end
  end

  @doc """
  Validates and normalizes one rule, for trading_live's changeset.

  `priority` defaults to `0` and `enabled` to `true`. `size_multiplier`
  must be a `Decimal` (or a decimal string) in `[0, 1]` for an `:allow`
  rule — the gate never upsizes. Floats are rejected rather than
  converted. For a `:block` rule `size_multiplier` is ignored and
  normalized to `nil`.
  """
  @spec validate_rule(map()) :: {:ok, rule()} | {:error, [atom()]}
  def validate_rule(attrs) when is_map(attrs) do
    rule = %{
      id: Map.get(attrs, :id),
      vol_state: Map.get(attrs, :vol_state),
      trend_state: Map.get(attrs, :trend_state),
      selector: Map.get(attrs, :selector),
      action: Map.get(attrs, :action),
      size_multiplier: Map.get(attrs, :size_multiplier),
      priority: Map.get(attrs, :priority, 0),
      enabled: Map.get(attrs, :enabled, true)
    }

    {multiplier, multiplier_errors} = validate_multiplier(rule.action, rule.size_multiplier)

    errors =
      [
        {is_binary(rule.id) and rule.id != "", :invalid_id},
        {rule.vol_state in [:any | @vol_states], :invalid_vol_state},
        {rule.trend_state in [:any | @trend_states], :invalid_trend_state},
        {valid_selector?(rule.selector), :invalid_selector},
        {rule.action in [:allow, :block], :invalid_action},
        {is_integer(rule.priority), :invalid_priority},
        {is_boolean(rule.enabled), :invalid_enabled}
      ]
      |> Enum.reject(fn {ok?, _} -> ok? end)
      |> Enum.map(fn {_, reason} -> reason end)
      |> Kernel.++(multiplier_errors)

    case errors do
      [] -> {:ok, %{rule | size_multiplier: multiplier}}
      errors -> {:error, errors}
    end
  end

  ## ---------------------------------------------------------------------

  defp parse(nil), do: :error

  defp parse(label) do
    case Regime.parse_label(label) do
      {:ok, cell} -> {:ok, cell}
      _ -> :error
    end
  end

  defp evaluate_cell(rules, ctx, {vol, trend}, opts) do
    rules
    |> Enum.filter(&(Map.get(&1, :enabled, true) and matches?(&1, ctx, vol, trend)))
    |> Enum.sort(&ranks_before?/2)
    |> case do
      [] -> fallback(Keyword.get(opts, :default, {:allow, Decimal.new(1)}), :default)
      [%{action: :block, id: id} | _] -> {:block, id}
      [%{action: :allow, id: id, size_multiplier: m} | _] -> {:allow, m, id}
    end
  end

  defp fallback(:block, source), do: {:block, source}
  defp fallback({:allow, %Decimal{} = m}, source), do: {:allow, m, source}

  defp fallback({:allow, m}, source) when is_integer(m) or is_binary(m),
    do: {:allow, Decimal.new(m), source}

  defp matches?(rule, ctx, vol, trend) do
    axis_matches?(rule.vol_state, vol) and axis_matches?(rule.trend_state, trend) and
      selector_matches?(rule.selector, ctx)
  end

  defp axis_matches?(:any, _), do: true
  defp axis_matches?(state, state), do: true
  defp axis_matches?(_, _), do: false

  defp selector_matches?(:all, _ctx), do: true
  defp selector_matches?({:strategy_id, id}, ctx), do: Map.get(ctx, :strategy_id) == id
  defp selector_matches?({:tag, tag}, ctx), do: tag in Map.get(ctx, :tags, [])
  defp selector_matches?({:exposure, e}, ctx), do: Map.get(ctx, :exposure) == e
  defp selector_matches?(_, _ctx), do: false

  # true when a should be chosen over b
  defp ranks_before?(a, b) do
    ka = {selector_rank(a.selector), label_rank(a), Map.get(a, :priority, 0)}
    kb = {selector_rank(b.selector), label_rank(b), Map.get(b, :priority, 0)}

    cond do
      ka > kb -> true
      ka < kb -> false
      true -> a.id <= b.id
    end
  end

  defp selector_rank({:strategy_id, _}), do: 4
  defp selector_rank({:tag, _}), do: 3
  defp selector_rank({:exposure, _}), do: 2
  defp selector_rank(:all), do: 1

  defp label_rank(rule) do
    Enum.count([rule.vol_state, rule.trend_state], &(&1 != :any))
  end

  defp valid_selector?(:all), do: true
  defp valid_selector?({:strategy_id, id}) when is_binary(id) and id != "", do: true
  defp valid_selector?({:tag, tag}) when is_binary(tag) and tag != "", do: true
  defp valid_selector?({:exposure, e}) when e in [:long_market, :short_market], do: true
  defp valid_selector?(_), do: false

  defp validate_multiplier(:block, _), do: {nil, []}

  defp validate_multiplier(:allow, value) do
    case parse_multiplier(value) do
      {:ok, m} ->
        if Decimal.compare(m, 0) != :lt and Decimal.compare(m, 1) != :gt,
          do: {m, []},
          else: {value, [:size_multiplier_out_of_range]}

      :error ->
        {value, [:invalid_size_multiplier]}
    end
  end

  defp validate_multiplier(_action, value), do: {value, []}

  defp parse_multiplier(%Decimal{} = m),
    do: if(Decimal.inf?(m) or Decimal.nan?(m), do: :error, else: {:ok, m})

  defp parse_multiplier(m) when is_integer(m), do: {:ok, Decimal.new(m)}

  defp parse_multiplier(m) when is_binary(m) do
    case Decimal.parse(m) do
      {d, ""} -> parse_multiplier(d)
      _ -> :error
    end
  end

  defp parse_multiplier(_), do: :error
end
