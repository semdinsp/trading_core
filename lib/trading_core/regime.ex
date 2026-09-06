defmodule TradingCore.Regime do
  @moduledoc """
  Pure regime-classification math: turns a handful of raw market readings
  (a VIX level, a price vs. its trailing SMA, a slope) into a small,
  stable `{vol_state, trend_state}` label — and the boundary/percentile
  math a caller (`trading_signal`) needs to compute those states from its
  own persisted session history.

  This is **analysis infrastructure, not a tradeable signal**: unlike
  every kind in `TradingCore.Signal.Spec`/`TradingCore.Signal.Compute`,
  nothing here is wired into that DAG, and it is not meant to be — a
  strategy conditioning its entry rules on a bucket that currently holds
  three observations is exactly the premature-promotion failure this
  module is scoped to avoid. Promote to a `Spec` kind only once there are
  ~20 sessions of history per bucket to make that meaningful.

  Same `TradingCore.Signals`-style constraints as the rest of this
  library: no `Repo`, no `GenServer`, no `DateTime.utc_now/0`, no feed of
  its own. Every function is plain data in, plain data out — a caller
  supplies whatever trailing history/boundaries it has already persisted;
  this module never fetches or remembers anything across calls.

  ## Why `Decimal`, not `float`, and why every returned value is rounded

  `TradingCore.Signals`'s own moduledoc documents multiple confirmed live
  incidents where an *unrounded* `Decimal` (from `Decimal.div/2`'s or
  `Decimal.sub/2`'s exact-precision output) sat in a rolling window and
  was re-read/re-diffed on every subsequent tick, causing
  multi-hundred-thousand-message mailbox backlogs and double-digit-MB
  per-process memory blowups. This module takes raw readings as
  `TradingCore.Signals.sample/0` (`Decimal.t() | float() | integer() |
  String.t()`, the same union every other function in this library
  accepts) rather than narrowing to `float()` — a caller building this
  from `trading_signal`'s own `Decimal`-typed Ecto-persisted history
  should never need to convert types just to call in here — and rounds
  every computed boundary/percentile to `:precision` (default
  #{8}) *before* it is returned, so nothing this module hands back is
  ever the raw, arbitrary-digit-count output of `Decimal.div/2`'s linear
  interpolation. A caller that stores `percentile_boundaries/2`'s return
  value verbatim (the intended use — "persist the boundaries used, per
  session") is therefore storing the same bounded-precision shape
  `TradingCore.Signals` already established as safe to keep in memory or
  a database column across many sessions, not a fresh unrounded value per
  session that could otherwise grow without bound the same way those
  confirmed incidents did.

  `classify_vol_absolute/2`'s band edges are the one place literal floats
  appear (`{15.0, 22.0}`) — those are caller-facing tuning knobs, not
  accumulated/stored state, so the memory concern above doesn't apply to
  them; they're compared via `Decimal.compare/2` against the (possibly
  `Decimal`) `vix_level` like everything else here, never left as a bare
  float in anything retained.

  ## Absolute vol bands over rolling percentiles, for now

  `classify_vol_absolute/2` (fixed VIX bands) is v1's primary vol
  encoding, not `classify_vol_percentile/2` (rolling-percentile bands) —
  a rolling 60-ish-session tercile churns on its own (dropping a single
  high day off the back of the window can flip a label with no change in
  today's actual reading), which is worse for a label meant to segment
  strategy expectancy than a boundary that only moves when someone
  deliberately revisits it. `classify_vol_percentile/2` still exists and
  is exercised by this module's own tests, but a caller should treat it
  as built-for-later, not wired into a live label by default — running
  both simultaneously as two disagreeing "the" label with no chosen
  source of truth is the failure mode to avoid. The intended trigger to
  revisit which encoding is primary: if the absolute-band and
  percentile-band classifications disagree for a large share of sessions
  once enough percentile history has accumulated, that's the signal this
  decision is worth reopening — not a fixed calendar date.

  Fixed bands carry their own known risk (VIX's "normal" range drifts
  across years/regimes — `TradingSignal.Signals.Regime`'s own moduledoc
  documents exactly this as the reason its live gate uses a self-zscore
  rather than an absolute level). `percentile_boundaries/2`'s rolling
  output is stored alongside the absolute label specifically so that risk
  is visible and testable later without a migration, per this module's
  own "store raw, derive label, re-bucket" design goal.
  """

  alias TradingCore.Signals

  @type vol_state :: :calm | :normal | :stressed
  @type trend_state :: :up | :chop | :down
  @type ordinal :: -1 | 0 | 1

  @default_precision 8

  # Below this many trailing observations, a tercile/percentile boundary
  # is too noisy to trust (each bucket would hold well under 10 points at
  # n=20 with two cut points) — same "not enough history yet" shape every
  # windowed TradingCore.Signals function already returns explicitly
  # rather than silently computing a low-confidence value.
  @min_history_for_percentiles 20

  @default_vol_bands {Decimal.new("15.0"), Decimal.new("22.0")}

  # Smallest slope magnitude treated as genuinely trending rather than
  # flat — below this, classify_trend/4 calls it :chop regardless of
  # which side of the SMA price sits on, so a barely-positive/negative
  # slope on an otherwise flat SMA doesn't get an :up/:down label from
  # noise alone. Same role @default_precision's rounding plays elsewhere:
  # a deliberate deadband, not a magic epsilon for float comparison (this
  # module never uses float equality).
  @default_slope_eps Decimal.new("0.0")

  ## ---------------------------------------------------------------------
  ## Boundary computation (from history)
  ## ---------------------------------------------------------------------

  @doc """
  Boundary values at each of `percentiles` (e.g. `[0.333, 0.667]` for
  terciles) within `values`, via linear interpolation between order
  statistics (the same method `:lists.nth/2`-style percentile
  calculators commonly call "R-7"/Excel's `PERCENTILE.INC`: sort
  ascending, index by `p * (n - 1)`, interpolate between the two
  surrounding ranks when that index isn't an integer).

  `values` may be given in any order (sorted internally) and as any mix
  of `TradingCore.Signals.sample/0` types; every element is normalized to
  `Decimal` before sorting/interpolating. Each boundary is rounded to
  `:precision` (default #{@default_precision}) before it's returned — see
  this module's moduledoc, "Why `Decimal`... and why every returned value
  is rounded," for why that rounding is load-bearing rather than
  cosmetic: the intended caller persists this return value verbatim as
  "the boundaries used, per session" (see this module's own point-in-time
  correctness design goal), so an unbounded-precision interpolation
  result would otherwise be the exact shape of value that design already
  guards against elsewhere in this library.

  Returns `{:error, :insufficient_history}` when `values` has fewer than
  #{@min_history_for_percentiles} entries — not enough observations for a
  percentile split to mean anything (see this module's moduledoc, "Absolute
  vol bands over rolling percentiles, for now").
  """
  @spec percentile_boundaries([Signals.sample()], [float()], keyword()) ::
          {:ok, [Decimal.t()]} | {:error, :insufficient_history}
  def percentile_boundaries(values, percentiles, opts \\ [])

  def percentile_boundaries(values, _percentiles, _opts)
      when length(values) < @min_history_for_percentiles do
    {:error, :insufficient_history}
  end

  def percentile_boundaries(values, percentiles, opts) do
    precision = Keyword.get(opts, :precision, @default_precision)

    sorted =
      values
      |> Enum.map(&to_decimal/1)
      |> Enum.sort({:asc, Decimal})

    boundaries =
      Enum.map(percentiles, fn p ->
        sorted
        |> interpolated_rank(p)
        |> Decimal.round(precision)
      end)

    {:ok, boundaries}
  end

  # R-7 / PERCENTILE.INC: rank = p * (n - 1), zero-indexed; interpolate
  # linearly between the two order statistics straddling a fractional
  # rank. n >= @min_history_for_percentiles is already guaranteed by the
  # caller clause above, so n - 1 >= 1 here — no divide-by-zero risk from
  # a single-element list.
  defp interpolated_rank(sorted, p) do
    n = length(sorted)
    rank = Decimal.mult(Decimal.from_float(p * 1.0), Decimal.new(n - 1))

    lower_index = rank |> Decimal.round(0, :floor) |> Decimal.to_integer()
    upper_index = min(lower_index + 1, n - 1)

    fraction = Decimal.sub(rank, Decimal.new(lower_index))

    lower_value = Enum.at(sorted, lower_index)
    upper_value = Enum.at(sorted, upper_index)

    upper_value
    |> Decimal.sub(lower_value)
    |> Decimal.mult(fraction)
    |> Decimal.add(lower_value)
  end

  ## ---------------------------------------------------------------------
  ## Classification
  ## ---------------------------------------------------------------------

  @doc "The default `{low, high}` absolute vol bands `classify_vol_absolute/2` uses when not given its own — `{15.0, 22.0}`. Exposed so a caller (e.g. hysteresis code deciding which boundary a state transition crossed) can reference the same bands without duplicating the literal."
  @spec default_vol_bands() :: {Decimal.t(), Decimal.t()}
  def default_vol_bands, do: @default_vol_bands

  @doc """
  Absolute-band volatility classification: `:calm` below the low band,
  `:stressed` at or above the high band, `:normal` in between. `bands`
  defaults to `{15.0, 22.0}` (v1's decided default — see this module's
  moduledoc). A reading exactly on a band edge classifies into the
  *higher* state (`vix_level == low` is `:normal`, not `:calm`;
  `vix_level == high` is `:stressed`, not `:normal`) — chosen so the
  three states partition the real line with no gap or overlap and no
  reading is ever ambiguous between two of them.
  """
  @spec classify_vol_absolute(Signals.sample(), {Signals.sample(), Signals.sample()}) ::
          vol_state()
  def classify_vol_absolute(vix_level, bands \\ @default_vol_bands) do
    {low, high} = bands
    level = to_decimal(vix_level)

    cond do
      Decimal.compare(level, to_decimal(low)) == :lt -> :calm
      Decimal.compare(level, to_decimal(high)) == :lt -> :normal
      true -> :stressed
    end
  end

  @doc """
  Rolling-percentile volatility classification: `:calm` below `b1`,
  `:stressed` at or above `b2`, `:normal` in between — same edge
  convention as `classify_vol_absolute/2`. `[b1, b2]` is the two-element
  list `percentile_boundaries/3` returns for `[0.333, 0.667]`-style
  terciles; this function does no percentile computation of its own, it
  only classifies against boundaries already computed and supplied by
  the caller (see this module's moduledoc, "Boundaries are always passed
  in").

  Built for later, not wired into a live label by default in v1 — see
  this module's moduledoc, "Absolute vol bands over rolling percentiles,
  for now."
  """
  @spec classify_vol_percentile(Signals.sample(), [Signals.sample()]) :: vol_state()
  def classify_vol_percentile(vix_level, [b1, b2]) do
    classify_vol_absolute(vix_level, {b1, b2})
  end

  @doc """
  Trend classification from a price/SMA pair and that SMA's own slope:
  `:up` when `price` sits above `sma` **and** `slope` exceeds
  `slope_eps`, `:down` when `price` sits below `sma` **and** `slope` is
  below `-slope_eps`, `:chop` otherwise (price/SMA and slope disagree on
  direction, or the slope is too flat to trust either way).

  `slope_eps` (`opts[:slope_eps]`, default `#{@default_slope_eps}`) is a
  deadband on `slope` alone — a deliberately flat SMA with price sitting
  a hair above/below it from noise shouldn't call a direction, same
  reasoning `TradingSignal.Signals.Regime`'s `tick_deadband` already
  applies to a breadth reading (see that module's own moduledoc). Pass a
  larger value to require a more decisive slope before calling `:up`/
  `:down`.
  """
  @spec classify_trend(Signals.sample(), Signals.sample(), Signals.sample(), keyword()) ::
          trend_state()
  def classify_trend(price, sma, slope, opts \\ []) do
    slope_eps = opts |> Keyword.get(:slope_eps, @default_slope_eps) |> to_decimal()

    price = to_decimal(price)
    sma = to_decimal(sma)
    slope = to_decimal(slope)

    cond do
      Decimal.compare(price, sma) == :gt and Decimal.compare(slope, slope_eps) == :gt ->
        :up

      Decimal.compare(price, sma) == :lt and
          Decimal.compare(slope, Decimal.negate(slope_eps)) == :lt ->
        :down

      true ->
        :chop
    end
  end

  ## ---------------------------------------------------------------------
  ## Encoding
  ## ---------------------------------------------------------------------

  @doc "Ordinal encoding of a `vol_state/0` or `trend_state/0`: low/down = -1, mid/chop = 0, high/up = 1."
  @spec ordinal(vol_state() | trend_state()) :: ordinal()
  def ordinal(:calm), do: -1
  def ordinal(:down), do: -1
  def ordinal(:normal), do: 0
  def ordinal(:chop), do: 0
  def ordinal(:stressed), do: 1
  def ordinal(:up), do: 1

  @doc """
  The combined display label for a `{vol_state, trend_state}` pair, e.g.
  `"calm|up"`. For grouping/display only — see this module's moduledoc;
  the ordinals from `ordinal/1`, not this string, are the primary key for
  any ordered analysis (e.g. "does expectancy rise monotonically with
  vol?") or a future third axis.
  """
  @spec label(vol_state(), trend_state()) :: String.t()
  def label(vol_state, trend_state) when vol_state in [:calm, :normal, :stressed] do
    "#{vol_state}|#{trend_state}"
  end

  @doc """
  Parses a `label/2`-produced string back into its `{vol_state,
  trend_state}` pair. `:error` for anything not in the 9 valid
  combinations (including case/whitespace variants) — this only ever
  needs to round-trip this module's own `label/2` output, not parse
  arbitrary user input.
  """
  @spec parse_label(String.t()) :: {:ok, {vol_state(), trend_state()}} | :error
  def parse_label(string) when is_binary(string) do
    case String.split(string, "|") do
      [vol, trend] -> parse_pair(vol, trend)
      _ -> :error
    end
  end

  def parse_label(_), do: :error

  @vol_states ~w(calm normal stressed)
  @trend_states ~w(up chop down)

  defp parse_pair(vol, trend) when vol in @vol_states and trend in @trend_states do
    {:ok, {String.to_existing_atom(vol), String.to_existing_atom(trend)}}
  end

  defp parse_pair(_vol, _trend), do: :error

  ## ---------------------------------------------------------------------
  ## Hysteresis
  ## ---------------------------------------------------------------------

  @doc """
  Sticky re-classification: returns `previous_state` unchanged unless
  `value` has crossed the boundary separating `previous_state` from
  `new_state` by more than `margin` — a reading that wobbles back and
  forth right at a boundary edge shouldn't flip the label on every
  evaluation (see this module's moduledoc/the handoff design goal,
  "label at decision points with hysteresis, not on every tick").

  Pure and stateless: the caller supplies `previous_state` on every call
  and stores whatever this returns as the next call's `previous_state` —
  this function itself remembers nothing between calls, same as every
  other function in this module.

  `new_state` is whatever the plain classifier (`classify_vol_absolute/2`,
  `classify_vol_percentile/2`, or `classify_trend/4`) already computed
  for `value` this evaluation. `boundary` is the single edge value
  between `previous_state` and `new_state` (the relevant element of a
  vol `bands`/percentile-boundaries tuple/list, or `sma` for the trend
  axis's price-vs-SMA edge) — the caller picks which boundary is
  relevant, since only it knows which two states are adjacent for its own
  axis. When `new_state == previous_state`, `boundary`/`margin` are never
  consulted (nothing crossed).

  Returns `new_state` unchanged (not just "flips or doesn't") whenever
  `new_state == previous_state` — this function only ever suppresses a
  *change*, it never invents a third outcome.
  """
  @spec stable_state(
          new_state,
          new_state,
          Signals.sample(),
          Signals.sample(),
          Signals.sample()
        ) :: new_state
        when new_state: vol_state() | trend_state()
  def stable_state(new_state, previous_state, _value, _boundary, _margin)
      when new_state == previous_state do
    new_state
  end

  def stable_state(new_state, previous_state, value, boundary, margin) do
    distance =
      value
      |> to_decimal()
      |> Decimal.sub(to_decimal(boundary))
      |> Decimal.abs()

    if Decimal.compare(distance, to_decimal(margin)) == :gt do
      new_state
    else
      previous_state
    end
  end

  ## ---------------------------------------------------------------------
  ## Shared helpers
  ## ---------------------------------------------------------------------

  defp to_decimal(%Decimal{} = value), do: value
  defp to_decimal(value) when is_float(value), do: Decimal.from_float(value)
  defp to_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp to_decimal(value) when is_binary(value), do: Decimal.new(value)
end
