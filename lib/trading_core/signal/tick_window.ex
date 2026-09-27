defmodule TradingCore.Signal.TickWindow do
  @moduledoc """
  Time windows over tick-level data that hold on busy symbols.

  `TradingCore.Signal.Compute`'s `:ofi`, `:signed_volume` and
  `:two_scale_rv` used to keep a plain list, trimmed to `window_ms` and
  then to a sample count (default 1,000). SPY and QQQ print thousands of
  trades and tens of thousands of quotes in five minutes, so the count
  bound first: a "5m" window really covered the last 10-60 seconds, and
  nothing said so. Rescanning a full-size list on every tick instead would
  cost O(n) per tick, which a live loop cannot afford at ~100 quotes/sec.

  Both structures here are updated in O(1) amortized time per tick:

    * `sum_*` — a running `Decimal` total of values in the window (for the
      additive kinds). Exact: values are added on arrival and subtracted
      on expiry, so the total equals re-summing the window.
    * `rv_*` — the two sums the tick-count two-scale realized-variance
      estimator needs (`TradingCore.Signals.two_scale_rv/2`): squared log
      returns at lag 1 and at lag `k`. Each pair is added when its newer
      price arrives and removed when its older price leaves, so the result
      matches the batch estimator over the same window (to float rounding;
      the sums are rebuilt from scratch every #{4096} pushes so rounding
      cannot accumulate).

  Both keep a safety cap on the number of points (the caller passes it).
  When the cap has to drop points that are still inside the window, the
  count is returned so the caller can report it (`state[:cap_bound_drops]`)
  — a shrunken window is never silent.
  """

  @resync_every 4096

  ## -------------------------------------------------------------------
  ## Running sum
  ## -------------------------------------------------------------------

  @type sum :: %{
          queue: :queue.queue({DateTime.t(), Decimal.t()}),
          total: Decimal.t(),
          size: non_neg_integer()
        }

  @spec sum_new() :: sum()
  def sum_new, do: %{queue: :queue.new(), total: Decimal.new(0), size: 0}

  @doc """
  Adds `value` at `at`, expires points older than `window_ms` before
  `now` (kept: `at >= now - window_ms`; `nil` window keeps everything),
  then enforces `max_samples`. Returns `{sum, cap_dropped}` where
  `cap_dropped` counts in-window points the cap removed.
  """
  @spec sum_push(
          sum(),
          DateTime.t(),
          Decimal.t(),
          DateTime.t(),
          pos_integer() | nil,
          pos_integer()
        ) ::
          {sum(), non_neg_integer()}
  def sum_push(%{queue: q, total: total, size: size}, at, value, now, window_ms, max_samples) do
    s = %{queue: :queue.in({at, value}, q), total: Decimal.add(total, value), size: size + 1}
    s = if window_ms, do: sum_expire(s, DateTime.add(now, -window_ms, :millisecond)), else: s
    sum_cap(s, max_samples, 0)
  end

  @spec sum_total(sum()) :: Decimal.t()
  def sum_total(%{total: total}), do: total

  @spec sum_size(sum()) :: non_neg_integer()
  def sum_size(%{size: size}), do: size

  defp sum_expire(%{queue: q} = s, cutoff) do
    case :queue.peek(q) do
      {:value, {at, _}} ->
        if DateTime.compare(at, cutoff) == :lt, do: s |> sum_pop() |> sum_expire(cutoff), else: s

      :empty ->
        s
    end
  end

  defp sum_cap(%{size: size} = s, max, dropped) when size > max,
    do: s |> sum_pop() |> sum_cap(max, dropped + 1)

  defp sum_cap(s, _max, dropped), do: {s, dropped}

  defp sum_pop(%{queue: q, total: total, size: size}) do
    {{:value, {_at, v}}, q} = :queue.out(q)
    %{queue: q, total: Decimal.sub(total, v), size: size - 1}
  end

  ## -------------------------------------------------------------------
  ## Two-scale realized variance (tick-count subsampling)
  ## -------------------------------------------------------------------

  @typedoc """
  Points are numbered by arrival (`lo`..`hi`). Each entry stores its
  timestamp, log price, and the squared differences to the points 1 and
  `k` before it (`nil` if that point was not in the window when it
  arrived).
  """
  @type rv :: %{
          k: pos_integer(),
          lo: integer(),
          hi: integer(),
          entries: %{integer() => {DateTime.t(), float(), float() | nil, float() | nil}},
          s1: float(),
          sk: float(),
          pushes: non_neg_integer()
        }

  @spec rv_new(pos_integer()) :: rv()
  def rv_new(k) when is_integer(k) and k > 0,
    do: %{k: k, lo: 0, hi: -1, entries: %{}, s1: 0.0, sk: 0.0, pushes: 0}

  @doc """
  Adds a trade price at `at`, then expires and caps exactly like
  `sum_push/6`. Returns `{rv, cap_dropped}`.
  """
  @spec rv_push(rv(), DateTime.t(), float(), DateTime.t(), pos_integer() | nil, pos_integer()) ::
          {rv(), non_neg_integer()}
  def rv_push(
        %{k: k, lo: lo, hi: hi, entries: entries} = rv,
        at,
        price,
        now,
        window_ms,
        max_samples
      ) do
    log = :math.log(price)
    seq = hi + 1
    d1 = if seq - 1 >= lo, do: sq(log - log_at(entries, seq - 1))
    dk = if seq - k >= lo, do: sq(log - log_at(entries, seq - k))

    rv = %{
      rv
      | hi: seq,
        entries: Map.put(entries, seq, {at, log, d1, dk}),
        s1: rv.s1 + (d1 || 0.0),
        sk: rv.sk + (dk || 0.0),
        pushes: rv.pushes + 1
    }

    rv = if window_ms, do: rv_expire(rv, DateTime.add(now, -window_ms, :millisecond)), else: rv
    {rv, dropped} = rv_cap(rv, max_samples, 0)

    rv = if rem(rv.pushes, @resync_every) == 0, do: rv_resync(rv), else: rv
    {rv, dropped}
  end

  @spec rv_size(rv()) :: non_neg_integer()
  def rv_size(%{lo: lo, hi: hi}), do: max(hi - lo + 1, 0)

  @doc """
  The two-scale realized variance of the prices in the window — the same
  formula as `TradingCore.Signals.two_scale_rv/2` (see it for the
  estimator, the `nil` and the clamp at zero). Raw variance over the
  window, not annualized.
  """
  @spec rv_value(rv()) :: float() | nil
  def rv_value(%{k: k, s1: s1, sk: sk} = rv) do
    n = rv_size(rv) - 1

    if n < k + 1 do
      nil
    else
      nbar = (n - k + 1) / k
      max(sk / k - nbar / n * s1, 0.0)
    end
  end

  # Removing the oldest point removes exactly the pairs it is the older
  # member of: lag 1 (stored on the next point) and lag k (stored k on).
  defp rv_pop(%{k: k, lo: lo, hi: hi, entries: entries} = rv) do
    s1 = if lo + 1 <= hi, do: rv.s1 - (d1_at(entries, lo + 1) || 0.0), else: rv.s1
    sk = if lo + k <= hi, do: rv.sk - (dk_at(entries, lo + k) || 0.0), else: rv.sk

    %{rv | lo: lo + 1, entries: Map.delete(entries, lo), s1: s1, sk: sk}
  end

  defp rv_expire(%{lo: lo, hi: hi, entries: entries} = rv, cutoff) when lo <= hi do
    {at, _, _, _} = Map.fetch!(entries, lo)
    if DateTime.compare(at, cutoff) == :lt, do: rv |> rv_pop() |> rv_expire(cutoff), else: rv
  end

  defp rv_expire(rv, _cutoff), do: rv

  defp rv_cap(rv, max, dropped) do
    if rv_size(rv) > max, do: rv |> rv_pop() |> rv_cap(max, dropped + 1), else: {rv, dropped}
  end

  # Rebuilds s1/sk from the stored logs, bounding float drift from the
  # add/subtract updates.
  defp rv_resync(%{k: k, lo: lo, hi: hi, entries: entries} = rv) when hi - lo >= 1 do
    logs = Enum.map(lo..hi, &log_at(entries, &1))
    %{rv | s1: lag_sum(logs, 1), sk: lag_sum(logs, k)}
  end

  defp rv_resync(rv), do: %{rv | s1: 0.0, sk: 0.0}

  defp lag_sum(logs, lag) do
    logs
    |> Enum.zip(Enum.drop(logs, lag))
    |> Enum.reduce(0.0, fn {a, b}, acc -> acc + sq(b - a) end)
  end

  defp log_at(entries, seq), do: entries |> Map.fetch!(seq) |> elem(1)
  defp d1_at(entries, seq), do: entries |> Map.fetch!(seq) |> elem(2)
  defp dk_at(entries, seq), do: entries |> Map.fetch!(seq) |> elem(3)

  defp sq(x), do: x * x
end
