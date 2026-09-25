defmodule TradingCore.Polygon.UnderlyingFeatures do
  @moduledoc """
  Rolling per-symbol features derived from `trading_hub`'s Polygon
  underlying feed, exposed to rule trees as `run_poly_*` snapshot keys.

  Moved here from `TradingOptionsSim.Pricing.PolygonFeatures` so
  `trading_options_sim` and `trading_live` compute identical `run_poly_*`
  values. A strategy's rule tree is promoted from one to the other
  byte-for-byte, so the same feed must give the same numbers in both.
  The key names are the ones stored in live rule trees; renaming one
  would break those rules silently.

  This module is only the pure part: `new/0`, the `apply_trade/3`,
  `apply_quote/3` and `apply_aggregate/3` folds, and `to_snapshot/2`.
  Each app keeps its own storage and process around it. In
  `trading_options_sim`, `PolygonRelay` folds every trade, quote and
  aggregate it relays into one `%UnderlyingFeatures{}` per symbol, keeps
  them in its own ETS table, and `ContractMonitor` merges the snapshot
  into every evaluation. The folds and `to_snapshot/2` take time as an
  argument (no wall clock here), so tests drive time directly rather
  than sleeping.

  ## Clock: the hub's stamp, not receive time

  Every value is dated with the message's own `data[:timestamp]` (a
  `DateTime` on trades, quotes and bars), falling back to the caller's
  `now` only when a message carries none. Receive time would make data
  that arrives late -- a hub catching up after a reconnect -- look
  fresh. A bar's stamp is Polygon's `"e"`, the bar END, so a bar is ~0s
  old on arrival and the 150s window tolerates one missed bar; Polygon
  sends no bar for a minute with no trades, so thin names age out and
  fail closed. Same convention as trading_live and trading_system.

  ## Keys

  | key | meaning | needs |
  |---|---|---|
  | `run_poly_last` | last trade price | trade in the last 30s |
  | `run_poly_spread_bps` | quoted spread, bps of mid | fresh quote |
  | `run_poly_imbalance` | `(bid_size - ask_size) / (bid_size + ask_size)`, -1..1 | fresh quote WITH both sizes |
  | `run_poly_imbalance_ema` | the same, time-decayed (10s time constant) | as above |
  | `run_poly_ret_1m_bps` / `run_poly_ret_5m_bps` | trade-price return over the window, bps | trade history spanning the window |
  | `run_poly_vwap_dev_bps` | last trade vs regular-session VWAP, bps | sized regular-hours trades today |
  | `run_poly_minute_volume` | latest per-minute bar volume | bar in the last 150s |
  | `run_poly_rel_volume` | latest bar / mean of up to 20 prior bars | ≥ 5 prior bars |

  ## Absent means unknown — never zero

  A key whose inputs are stale, incomplete or not yet warmed up is
  **omitted**, not set to `0`. `TradingCore.RuleEngine` fails closed on
  a missing key, which is the correct behaviour: a quote without sizes
  has an *unknown* imbalance, and reporting `0.0` would let an
  `imbalance < 0.1` rule fire on no information at all. Same rule for a
  zero denominator (sizes `0/0`, an empty VWAP).

  ## Sampling

  Returns read a trade-price buffer sampled at most once per second and
  kept for 6 minutes, so memory is bounded
  regardless of tick rate. A return is only reported when the buffer
  holds a sample at or before the window start and that sample is not
  more than 30s older than it — a gap in the feed yields no value
  rather than a return measured over a silently longer window.
  """

  @fresh_ms 30_000
  @volume_fresh_ms 150_000
  @sample_every_ms 1_000
  @buffer_ms 360_000
  @window_slack_ms 30_000
  @ema_tau_ms 10_000
  @volume_history 20
  @min_volume_history 5

  defstruct quote: nil,
            quote_at: nil,
            imbalance_ema: nil,
            imbalance_at: nil,
            last_trade: nil,
            last_trade_at: nil,
            samples: :queue.new(),
            last_sample_at: nil,
            vwap_date: nil,
            vwap_pv: 0.0,
            vwap_v: 0.0,
            bar_volume: nil,
            bar_at: nil,
            prior_bars: []

  @type t :: %__MODULE__{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  # --- Folds ----------------------------------------------------------------

  @spec apply_trade(t(), map(), integer()) :: t()
  def apply_trade(%__MODULE__{} = f, data, now) do
    now = event_ms(data, now)

    case to_float(Map.get(data, :last)) do
      price when is_float(price) and price > 0 ->
        f
        |> update_last_trade(price, now)
        |> sample(price, now)
        |> accumulate_vwap(price, to_float(Map.get(data, :size)), Map.get(data, :timestamp))

      _ ->
        f
    end
  end

  @spec apply_quote(t(), map(), integer()) :: t()
  def apply_quote(%__MODULE__{} = f, data, now) do
    now = event_ms(data, now)
    bid = to_float(Map.get(data, :bid))
    ask = to_float(Map.get(data, :ask))

    if is_float(bid) and is_float(ask) and bid > 0 and ask >= bid do
      q = %{
        bid: bid,
        ask: ask,
        bid_size: to_float(Map.get(data, :bid_size)),
        ask_size: to_float(Map.get(data, :ask_size))
      }

      %{f | quote: q, quote_at: now} |> update_ema(imbalance(q), now)
    else
      f
    end
  end

  @spec apply_aggregate(t(), map(), integer()) :: t()
  def apply_aggregate(%__MODULE__{} = f, data, now) do
    now = event_ms(data, now)

    case to_float(Map.get(data, :volume)) do
      v when is_float(v) and v >= 0 ->
        prior =
          if is_nil(f.bar_volume),
            do: f.prior_bars,
            else: Enum.take([f.bar_volume | f.prior_bars], @volume_history)

        %{f | bar_volume: v, bar_at: now, prior_bars: prior}

      _ ->
        f
    end
  end

  # --- Snapshot -------------------------------------------------------------

  @spec to_snapshot(t(), integer()) :: map()
  def to_snapshot(%__MODULE__{} = f, now) do
    quote_fresh? = fresh?(f.quote_at, now, @fresh_ms)
    imbalance_fresh? = fresh?(f.imbalance_at, now, @fresh_ms)
    trade_fresh? = fresh?(f.last_trade_at, now, @fresh_ms)
    bar_fresh? = fresh?(f.bar_at, now, @volume_fresh_ms)

    [
      {"run_poly_last", trade_fresh? && f.last_trade},
      {"run_poly_spread_bps", quote_fresh? && spread_bps(f.quote)},
      {"run_poly_imbalance", quote_fresh? && imbalance(f.quote)},
      {"run_poly_imbalance_ema", imbalance_fresh? && f.imbalance_ema},
      {"run_poly_ret_1m_bps", trade_fresh? && return_bps(f, 60_000, now)},
      {"run_poly_ret_5m_bps", trade_fresh? && return_bps(f, 300_000, now)},
      {"run_poly_vwap_dev_bps", trade_fresh? && vwap_dev_bps(f, now)},
      {"run_poly_minute_volume", bar_fresh? && f.bar_volume},
      {"run_poly_rel_volume", bar_fresh? && rel_volume(f)}
    ]
    |> Enum.filter(fn {_k, v} -> is_number(v) end)
    |> Map.new()
  end

  # --- Internals ------------------------------------------------------------

  defp event_ms(%{timestamp: %DateTime{} = ts}, _fallback),
    do: DateTime.to_unix(ts, :millisecond)

  defp event_ms(_data, fallback), do: fallback

  defp fresh?(nil, _now, _max), do: false
  defp fresh?(at, now, max), do: now - at <= max

  defp spread_bps(%{bid: bid, ask: ask}) do
    mid = (bid + ask) / 2
    (ask - bid) / mid * 10_000
  end

  defp imbalance(%{bid_size: b, ask_size: a}) when is_float(b) and is_float(a) and b + a > 0,
    do: (b - a) / (b + a)

  defp imbalance(_quote), do: nil

  # A quote with unknown sizes leaves the EMA where it was rather than
  # pulling it toward zero. Freshness and decay both run off the last
  # SIZED quote (imbalance_at), not quote_at: a run of size-less quotes
  # must neither keep an old EMA looking current nor shrink the decay
  # interval of the next real reading.
  defp update_ema(f, nil, _now), do: f

  defp update_ema(%{imbalance_ema: nil} = f, x, now),
    do: %{f | imbalance_ema: x, imbalance_at: now}

  defp update_ema(%{imbalance_ema: ema, imbalance_at: prev_at} = f, x, now) do
    alpha = 1 - :math.exp(-max(now - prev_at, 0) / @ema_tau_ms)
    %{f | imbalance_ema: ema + alpha * (x - ema), imbalance_at: now}
  end

  # A trade older than the current last trade (a hub replaying after a
  # reconnect, delivered out of order) must not move last_trade back to a
  # stale price that still looks fresh. It still counts toward the VWAP:
  # a late print is real volume, and VWAP doesn't depend on order. The
  # return sampler ignores it too (sample/3's `now - last_sample_at >=
  # 1000` guard fails for an older `now`), so a replay can't pull the
  # returns back either.
  defp update_last_trade(%{last_trade_at: at} = f, _price, now)
       when is_integer(at) and now < at,
       do: f

  defp update_last_trade(f, price, now), do: %{f | last_trade: price, last_trade_at: now}

  defp sample(%{last_sample_at: last} = f, price, now)
       when is_nil(last) or now - last >= @sample_every_ms do
    samples = drop_old(:queue.in({now, price}, f.samples), now - @buffer_ms)
    %{f | samples: samples, last_sample_at: now}
  end

  defp sample(f, _price, _now), do: f

  defp drop_old(q, cutoff) do
    case :queue.peek(q) do
      {:value, {at, _}} when at < cutoff -> drop_old(:queue.drop(q), cutoff)
      _ -> q
    end
  end

  # The newest sample at or before the window start; nil if the buffer
  # doesn't reach back that far or the nearest sample is too old.
  defp return_bps(%{last_trade: last} = f, window, now) do
    start = now - window

    base =
      f.samples
      |> :queue.to_list()
      |> Enum.take_while(fn {at, _} -> at <= start end)
      |> List.last()

    case base do
      {at, price} when start - at <= @window_slack_ms -> (last - price) / price * 10_000
      _ -> nil
    end
  end

  defp accumulate_vwap(f, _price, size, _ts) when not is_float(size) or size <= 0, do: f
  defp accumulate_vwap(f, _price, _size, nil), do: f

  defp accumulate_vwap(f, price, size, %DateTime{} = ts) do
    case regular_session_date(ts) do
      nil ->
        f

      date when date == f.vwap_date ->
        %{f | vwap_pv: f.vwap_pv + price * size, vwap_v: f.vwap_v + size}

      # Only a LATER session starts a new VWAP. A late or replayed print
      # from an earlier session is ignored rather than wiping today's.
      date ->
        if is_nil(f.vwap_date) or Date.compare(date, f.vwap_date) == :gt,
          do: %{f | vwap_date: date, vwap_pv: price * size, vwap_v: size},
          else: f
    end
  end

  defp accumulate_vwap(f, _price, _size, _ts), do: f

  # ET trading date if `ts` falls in 09:30-16:00 ET, else nil.
  # Pre/post-market prints are excluded so the VWAP matches the one a
  # chart would show for the regular session.
  defp regular_session_date(ts) do
    case DateTime.shift_zone(ts, "America/New_York") do
      {:ok, et} ->
        t = Time.new!(et.hour, et.minute, et.second)

        if Time.compare(t, ~T[09:30:00]) != :lt and Time.compare(t, ~T[16:00:00]) == :lt,
          do: DateTime.to_date(et)

      _ ->
        nil
    end
  end

  # Yesterday's VWAP is not today's: before today's first regular-hours
  # print, report nothing rather than a deviation from a stale session.
  defp vwap_dev_bps(%{vwap_v: v}, _now) when v <= 0, do: nil

  defp vwap_dev_bps(%{vwap_pv: pv, vwap_v: v, last_trade: last, vwap_date: date}, now) do
    if date == et_date(now) do
      vwap = pv / v
      (last - vwap) / vwap * 10_000
    end
  end

  defp et_date(now_ms) do
    now_ms
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.shift_zone!("America/New_York")
    |> DateTime.to_date()
  end

  defp rel_volume(%{prior_bars: prior}) when length(prior) < @min_volume_history, do: nil

  defp rel_volume(%{prior_bars: prior, bar_volume: v}) do
    mean = Enum.sum(prior) / length(prior)
    if mean > 0, do: v / mean
  end

  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(n) when is_float(n), do: n
  defp to_float(n) when is_integer(n), do: n * 1.0
  defp to_float(_), do: nil
end
