defmodule TradingCore.MarketContext do
  @moduledoc """
  The per-trade market-context stamp (market_context v#{1}) that
  trading_options_sim, trading_live and trading_system write on every
  entry and exit fill. Defining it once here keeps the three apps from
  drifting apart.

  **Recording only, never a trading gate.** The stamp exists so trades
  can be segmented after the fact. Nothing should decide whether to trade
  from it; gates have their own inputs (e.g. `TradingCore.Regime.Playbook`).

  Pure and cheap: `build/3` runs on each fill, does no I/O and keeps no
  state. Its output is a JSON-safe map with string keys and only
  strings, integers, `true` and nested maps as values, never a `Decimal`
  or a float, so nothing unbounded is held in long-lived state.

  ## Keys

  `keys/0` lists the top-level keys in a stable order. A key whose value
  is unknown, nil, stale or of the wrong type is **omitted**, never
  written as 0. Each app merges its own `"extra"` map; it isn't built
  here.

  - `"market_context_version"` (integer) and `"captured_at"` (`now`).
  - Regime group, from trading_signal's `Regime.SessionLabel` payload:
    `"regime_label"`, `"regime_trend_ordinal"`, `"regime_vol_ordinal"`
    (−1/0/1, `TradingCore.Regime.ordinal/1`),
    `"regime_vol_percentile_state"` (categorical string, not a number),
    `"vix_level"`, `"spy_slope_20"`, `"spy_price"`, `"spy_sma_20"`,
    `"regime_session_date"`.
  - Gamma, whole dollars of delta-hedging per 1% move (sign = regime):
    `"gamma_{spy,qqq}_ex0dte"`, `"gamma_spx_combined_ex0dte"`,
    `"gamma_{spy,qqq}_all"`, `"gamma_spx_combined_all"`.
  - Returns since the prior close, in percent:
    `"{spy,qqq}_return_since_prior_close"`.
  - Noise-band ratio, unitless: `"{spy,qqq}_noise_band_ratio"`.
  - Opening range, integers −1/0/+1:
    `"{spy,qqq}_opening_range_position_{5,15,30}m"` and
    `"{spy,qqq}_opening_range_direction_{5,15,30}m"`.
  - `"as_of"`: `%{key => ISO8601}`, the `received_at` of each
    signal-sourced key present, plus `"regime"` (the payload's
    `evaluated_at`) when the regime group is present.
  - `"out_of_session"`: `true` when `now` is outside the US-equities
    regular session (09:30 ET to 16:00, or the early close on a half
    day; weekends and holidays have no session). Omitted otherwise.

  ## Serialization

  Numbers become decimal strings (lossless; floats via
  `Decimal.from_float/1`'s shortest form, written without exponents).
  Ordinals and opening-range values are integers. Labels and categorical
  states are strings. Timestamps are ISO8601 UTC strings and dates are
  ISO8601 date strings.

  ## Freshness

  - **Regime group:** kept only when the payload's `session_date` is the
    America/New_York calendar date of `now`; otherwise the whole group
    (and `as_of["regime"]`) is omitted. This deliberately does not use
    `TradingCore.Session.us_equities/1`, which maps a pre-open time to
    the prior session and would let yesterday's label through. There is
    no age rule on regime keys: `SessionLabel` re-evaluates every 30
    minutes but broadcasts only on change.
  - **Signal keys:** omitted when `now − received_at` exceeds 12 minutes
    for gamma, or 2 minutes for returns, noise band and opening range.
    Upstream `{:signal_cleared}` doesn't fire when a feed silently goes
    quiet, so the stamp has to time values out itself.

  ## Gamma caveats

  Gamma is a research filter, not a measurement. It comes from Cboe's
  unofficial, ~15-minute-delayed chains and assumes the conventional
  dealer positioning (long calls, short puts); open interest only
  updates overnight, and the value persists for 10 minutes upstream.
  Ignore SPX/combined gamma before about 10:30 ET, when Cboe's SPX spot
  lags. The planned Cboe → Massive source swap keeps the same slugs; it
  is a HISTORY_ERAS boundary, not a new key.

  ## Versioning

  Bump `version/0` whenever the key set or any key's meaning changes, so
  stored stamps can be told apart.
  """

  alias TradingCore.Intraday.RegularSession
  alias TradingCore.Regime
  alias TradingCore.Regime.Decimals

  @version 1
  @timezone "America/New_York"
  @gamma_max_age 12 * 60
  @fast_max_age 2 * 60

  @regime_keys [
    "regime_label",
    "regime_trend_ordinal",
    "regime_vol_ordinal",
    "regime_vol_percentile_state",
    "vix_level",
    "spy_slope_20",
    "spy_price",
    "spy_sma_20",
    "regime_session_date"
  ]

  # {output key, trading_signal slug, kind}; kind sets the freshness
  # limit and the serialization.
  @signals [
             {"gamma_spy_ex0dte", "cboe_spy_gamma_exposure_ex0dte", :gamma},
             {"gamma_qqq_ex0dte", "cboe_qqq_gamma_exposure_ex0dte", :gamma},
             {"gamma_spx_combined_ex0dte", "cboe_sp500_combined_gamma_exposure_ex0dte", :gamma},
             {"gamma_spy_all", "cboe_spy_gamma_exposure", :gamma},
             {"gamma_qqq_all", "cboe_qqq_gamma_exposure", :gamma},
             {"gamma_spx_combined_all", "cboe_sp500_combined_gamma_exposure", :gamma},
             {"spy_return_since_prior_close", "massive_spy_return_since_prior_close", :number},
             {"qqq_return_since_prior_close", "massive_qqq_return_since_prior_close", :number},
             {"spy_noise_band_ratio", "massive_spy_noise_band_ratio", :number},
             {"qqq_noise_band_ratio", "massive_qqq_noise_band_ratio", :number}
           ] ++
             for(
               symbol <- ["spy", "qqq"],
               kind <- ["position", "direction"],
               minutes <- [5, 15, 30],
               do:
                 {"#{symbol}_opening_range_#{kind}_#{minutes}m",
                  "massive_#{symbol}_opening_range_#{kind}_#{minutes}m", :ordinal}
             )

  @keys ["market_context_version", "captured_at"] ++
          @regime_keys ++
          Enum.map(@signals, &elem(&1, 0)) ++
          ["as_of", "out_of_session"]

  @doc "The stamp's schema version; see Versioning in the moduledoc."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "Every top-level key `build/3` can write, in a stable order."
  @spec keys() :: [String.t()]
  def keys, do: @keys

  @doc """
  Builds the stamp at `now` from trading_signal's regime payload (`nil`
  for none; atom or string keys) and its latest signal values
  (`%{slug => {value, received_at}}`). See the moduledoc for keys,
  serialization and freshness.
  """
  @spec build(map() | nil, %{optional(String.t()) => {term(), DateTime.t()}}, DateTime.t()) ::
          map()
  def build(regime_payload, signal_values, %DateTime{} = now) do
    {regime, regime_as_of} = regime_group(regime_payload, now)
    {signals, signal_as_of} = signal_group(signal_values || %{}, now)
    as_of = Map.merge(signal_as_of, regime_as_of)

    %{"market_context_version" => @version, "captured_at" => iso(now)}
    |> Map.merge(regime)
    |> Map.merge(signals)
    |> put_unless_empty("as_of", as_of)
    |> put_if("out_of_session", out_of_session?(now))
  end

  ## ---------------------------------------------------------------------
  ## Regime group
  ## ---------------------------------------------------------------------

  defp regime_group(payload, now) when is_map(payload) do
    with {:ok, session_date} <- to_date(field(payload, :session_date)),
         true <- Date.compare(session_date, et_date(now)) == :eq do
      group =
        %{
          "regime_label" => string(field(payload, :label)),
          "regime_trend_ordinal" => ordinal(field(payload, :trend_state), [:up, :chop, :down]),
          "regime_vol_ordinal" =>
            ordinal(field(payload, :vol_state), [:calm, :normal, :stressed]),
          "regime_vol_percentile_state" => string(field(payload, :vol_state_percentile)),
          "vix_level" => number(field(payload, :vix_level)),
          "spy_slope_20" => number(field(payload, :spy_slope_20)),
          "spy_price" => number(field(payload, :spy_price)),
          "spy_sma_20" => number(field(payload, :spy_sma_20)),
          "regime_session_date" => Date.to_iso8601(session_date)
        }
        |> reject_nil()

      as_of =
        case field(payload, :evaluated_at) do
          %DateTime{} = at -> %{"regime" => iso(at)}
          _ -> %{}
        end

      {group, as_of}
    else
      _ -> {%{}, %{}}
    end
  end

  defp regime_group(_payload, _now), do: {%{}, %{}}

  defp field(payload, key) do
    case Map.fetch(payload, key) do
      {:ok, value} -> value
      :error -> Map.get(payload, Atom.to_string(key))
    end
  end

  defp to_date(%Date{} = date), do: {:ok, date}
  defp to_date(string) when is_binary(string), do: Date.from_iso8601(string)
  defp to_date(_), do: :error

  defp ordinal(state, valid) when is_atom(state) and not is_nil(state) do
    if state in valid, do: Regime.ordinal(state)
  end

  defp ordinal(state, valid) when is_binary(state) do
    Enum.find_value(valid, fn atom ->
      if Atom.to_string(atom) == state, do: Regime.ordinal(atom)
    end)
  end

  defp ordinal(_state, _valid), do: nil

  ## ---------------------------------------------------------------------
  ## Signal group
  ## ---------------------------------------------------------------------

  defp signal_group(values, now) when is_map(values) do
    Enum.reduce(@signals, {%{}, %{}}, fn {key, slug, kind}, {acc, as_of} ->
      with {value, %DateTime{} = received_at} <- Map.get(values, slug),
           true <- fresh?(received_at, now, kind),
           serialized when not is_nil(serialized) <- serialize(value, kind) do
        {Map.put(acc, key, serialized), Map.put(as_of, key, iso(received_at))}
      else
        _ -> {acc, as_of}
      end
    end)
  end

  defp signal_group(_values, _now), do: {%{}, %{}}

  defp fresh?(received_at, now, kind) do
    max_age = if kind == :gamma, do: @gamma_max_age, else: @fast_max_age
    DateTime.diff(now, received_at, :second) <= max_age
  end

  defp serialize(value, :ordinal), do: ordinal_value(value)
  defp serialize(value, _number_kind), do: number(value)

  # −1, 0 or 1, given as an integer or an integral number.
  defp ordinal_value(value) when value in [-1, 0, 1], do: value

  defp ordinal_value(value) do
    with {:ok, d} <- Decimals.parse(value),
         true <- Decimal.integer?(d),
         int when int in [-1, 0, 1] <- Decimal.to_integer(d) do
      int
    else
      _ -> nil
    end
  end

  ## ---------------------------------------------------------------------
  ## Session and serialization helpers
  ## ---------------------------------------------------------------------

  defp out_of_session?(now) do
    case RegularSession.bounds(et_date(now)) do
      {:ok, open, close} ->
        DateTime.compare(now, open) == :lt or DateTime.compare(now, close) != :lt

      :error ->
        true
    end
  end

  defp et_date(now), do: now |> DateTime.shift_zone!(@timezone) |> DateTime.to_date()

  defp number(value) do
    case Decimals.parse(value) do
      {:ok, d} -> Decimal.to_string(d, :normal)
      :error -> nil
    end
  end

  defp string(value) when is_binary(value) and value != "", do: value

  defp string(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp string(_value), do: nil

  defp iso(%DateTime{} = at), do: at |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_iso8601()

  defp reject_nil(map), do: map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()

  defp put_unless_empty(map, _key, empty) when map_size(empty) == 0, do: map
  defp put_unless_empty(map, key, value), do: Map.put(map, key, value)

  defp put_if(map, key, true), do: Map.put(map, key, true)
  defp put_if(map, _key, false), do: map
end
