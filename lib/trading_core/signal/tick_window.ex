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

  ## -------------------------------------------------------------------
  ## Monotonic deques (shared by extremes and OLS)
  ## -------------------------------------------------------------------

  # A :queue of {seq, value}, oldest at the front, whose values are
  # strictly decreasing (for :max) or increasing (for :min) toward the
  # back. The front is the window's extreme. A new value evicts every
  # entry at the back it beats or ties — those can never be the extreme
  # again while it is in the window, since it is newer.
  defp mono_push(q, seq, value, kind) do
    case :queue.peek_r(q) do
      {:value, {_s, v}} ->
        if dominated?(v, value, kind),
          do: mono_push(:queue.drop_r(q), seq, value, kind),
          else: :queue.in({seq, value}, q)

      :empty ->
        :queue.in({seq, value}, q)
    end
  end

  defp dominated?(old, new, :max), do: cmp(old, new) != :gt
  defp dominated?(old, new, :min), do: cmp(old, new) != :lt

  # Drops front entries whose seq has left the window (seq < lo).
  defp mono_expire(q, lo) do
    case :queue.peek(q) do
      {:value, {s, _}} when s < lo -> mono_expire(:queue.drop(q), lo)
      _ -> q
    end
  end

  defp mono_front(q) do
    {:value, {_s, v}} = :queue.peek(q)
    v
  end

  defp cmp(%Decimal{} = a, %Decimal{} = b), do: Decimal.compare(a, b)
  defp cmp(a, b) when a > b, do: :gt
  defp cmp(a, b) when a < b, do: :lt
  defp cmp(_a, _b), do: :eq

  defp cap(q, lo, size, max, dropped) when size > max,
    do: cap(:queue.drop(q), lo + 1, size - 1, max, dropped + 1)

  defp cap(q, lo, size, _max, dropped), do: {q, lo, size, dropped}

  ## -------------------------------------------------------------------
  ## Window extremes (Donchian)
  ## -------------------------------------------------------------------

  @typedoc "High/low of the prices in a time window, via monotonic deques."
  @type extremes :: %{
          points: :queue.queue(),
          lo: non_neg_integer(),
          next: non_neg_integer(),
          size: non_neg_integer(),
          max: :queue.queue(),
          min: :queue.queue(),
          latest: Decimal.t() | nil
        }

  @spec extremes_new() :: extremes()
  def extremes_new,
    do: %{
      points: :queue.new(),
      lo: 0,
      next: 0,
      size: 0,
      max: :queue.new(),
      min: :queue.new(),
      latest: nil
    }

  @doc """
  Adds `price` at `at`, expires and caps like `sum_push/6`. Returns
  `{extremes, cap_dropped}`. O(1) amortized per push.
  """
  @spec extremes_push(
          extremes(),
          DateTime.t(),
          Decimal.t(),
          DateTime.t(),
          pos_integer() | nil,
          pos_integer()
        ) ::
          {extremes(), non_neg_integer()}
  def extremes_push(%{next: seq} = e, at, price, now, window_ms, max_samples) do
    # Points are {seq, at_us}: integer microseconds, not DateTimes, so a
    # long window on a busy symbol costs ~40 bytes a tick rather than
    # ~200, and expiry is an integer compare.
    now_us = DateTime.to_unix(now, :microsecond)
    points = :queue.in({seq, DateTime.to_unix(at, :microsecond)}, e.points)

    {points, lo, size} =
      if window_ms,
        do: expire_us(points, e.lo, e.size + 1, now_us - window_ms * 1_000),
        else: {points, e.lo, e.size + 1}

    {points, lo, size, dropped} = cap(points, lo, size, max_samples, 0)

    e = %{
      e
      | points: points,
        lo: lo,
        next: seq + 1,
        size: size,
        max: e.max |> mono_push(seq, price, :max) |> mono_expire(lo),
        min: e.min |> mono_push(seq, price, :min) |> mono_expire(lo),
        latest: price
    }

    {e, dropped}
  end

  @doc """
  `{upper, middle, lower}` over the window, or `nil` with fewer than two
  prices — the same contract as `TradingCore.Signals.donchian_bands/1`.
  """
  @spec extremes_bands(extremes()) :: {Decimal.t(), Decimal.t(), Decimal.t()} | nil
  def extremes_bands(%{size: size}) when size < 2, do: nil

  def extremes_bands(%{max: max, min: min}) do
    upper = mono_front(max)
    lower = mono_front(min)
    {upper, Decimal.div(Decimal.add(upper, lower), 2), lower}
  end

  @doc "`{newest_at, oldest_at}` of the prices in the window, or `nil` if empty."
  @spec extremes_span(extremes()) :: {DateTime.t(), DateTime.t()} | nil
  def extremes_span(%{size: 0}), do: nil

  def extremes_span(%{points: points}) do
    {:value, {_, oldest}} = :queue.peek(points)
    {:value, {_, newest}} = :queue.peek_r(points)
    {DateTime.from_unix!(newest, :microsecond), DateTime.from_unix!(oldest, :microsecond)}
  end

  defp expire_us(q, lo, size, cutoff_us) do
    case :queue.peek(q) do
      {:value, {_seq, at_us}} when at_us < cutoff_us ->
        expire_us(:queue.drop(q), lo + 1, size - 1, cutoff_us)

      _ ->
        {q, lo, size}
    end
  end

  @spec extremes_size(extremes()) :: non_neg_integer()
  def extremes_size(%{size: size}), do: size

  @spec extremes_latest(extremes()) :: Decimal.t() | nil
  def extremes_latest(%{latest: latest}), do: latest

  ## -------------------------------------------------------------------
  ## Rolling OLS (kyle_lambda)
  ## -------------------------------------------------------------------

  @typedoc """
  Least-squares fit of y on x over a time window, kept as running means
  and centred co-moments (Welford), updated as points enter and leave.
  `xmax`/`xmin` track the window's x range so "every x identical" (a
  vertical line, no fit) is detected exactly rather than through a
  rounding-sized variance.
  """
  @type ols :: %{
          points: :queue.queue(),
          lo: non_neg_integer(),
          next: non_neg_integer(),
          size: non_neg_integer(),
          mx: float(),
          my: float(),
          cxy: float(),
          mxx: float(),
          xmax: :queue.queue(),
          xmin: :queue.queue(),
          ops: non_neg_integer()
        }

  @spec ols_new() :: ols()
  def ols_new do
    %{
      points: :queue.new(),
      lo: 0,
      next: 0,
      size: 0,
      mx: 0.0,
      my: 0.0,
      cxy: 0.0,
      mxx: 0.0,
      xmax: :queue.new(),
      xmin: :queue.new(),
      ops: 0
    }
  end

  @doc """
  Adds the point `(x, y)` at `at`, expires and caps like `sum_push/6`.
  Returns `{ols, cap_dropped}`. O(1) amortized; the moments are rebuilt
  from the stored points every #{4096} updates so float error cannot
  accumulate.
  """
  @spec ols_push(
          ols(),
          DateTime.t(),
          float(),
          float(),
          DateTime.t(),
          pos_integer() | nil,
          pos_integer()
        ) ::
          {ols(), non_neg_integer()}
  def ols_push(%{next: seq} = o, at, x, y, now, window_ms, max_samples) do
    o = o |> ols_add(x, y) |> Map.update!(:points, &:queue.in({seq, at, {x, y}}, &1))

    o = %{
      o
      | next: seq + 1,
        xmax: mono_push(o.xmax, seq, x, :max),
        xmin: mono_push(o.xmin, seq, x, :min)
    }

    {o, dropped} = ols_trim(o, now, window_ms, max_samples)

    o = %{o | xmax: mono_expire(o.xmax, o.lo), xmin: mono_expire(o.xmin, o.lo), ops: o.ops + 1}
    o = if rem(o.ops, @resync_every) == 0, do: ols_resync(o), else: o
    {o, dropped}
  end

  @doc """
  `{beta, alpha}` (floats) of `y = beta * x + alpha` over the window, or
  `nil` with fewer than two points or when every x is identical — the
  same contract as `TradingCore.Signals.rolling_ols_beta/4`'s fit.
  """
  @spec ols_value(ols()) :: {float(), float()} | nil
  def ols_value(%{size: size}) when size < 2, do: nil

  def ols_value(%{xmax: xmax, xmin: xmin} = o) do
    if mono_front(xmax) == mono_front(xmin) or o.mxx <= 0.0 do
      nil
    else
      beta = o.cxy / o.mxx
      {beta, o.my - beta * o.mx}
    end
  end

  @spec ols_size(ols()) :: non_neg_integer()
  def ols_size(%{size: size}), do: size

  # Pops expired, then capped, points off the front, removing each from
  # the moments.
  defp ols_trim(o, now, window_ms, max, dropped \\ 0) do
    cutoff = if window_ms, do: DateTime.add(now, -window_ms, :millisecond)

    case :queue.peek(o.points) do
      {:value, {_seq, at, {x, y}}} ->
        cond do
          cutoff && DateTime.compare(at, cutoff) == :lt ->
            o |> ols_pop(x, y) |> ols_trim(now, window_ms, max, dropped)

          o.size > max ->
            o |> ols_pop(x, y) |> ols_trim(now, window_ms, max, dropped + 1)

          true ->
            {o, dropped}
        end

      :empty ->
        {o, dropped}
    end
  end

  defp ols_pop(o, x, y) do
    %{ols_remove(o, x, y) | points: :queue.drop(o.points), lo: o.lo + 1}
  end

  defp ols_add(%{size: n, mx: mx, my: my} = o, x, y) do
    n1 = n + 1
    dx = x - mx
    mx1 = mx + dx / n1
    my1 = my + (y - my) / n1
    %{o | size: n1, mx: mx1, my: my1, cxy: o.cxy + dx * (y - my1), mxx: o.mxx + dx * (x - mx1)}
  end

  # The exact inverse of ols_add/3.
  defp ols_remove(%{size: 1} = o, _x, _y),
    do: %{o | size: 0, mx: 0.0, my: 0.0, cxy: 0.0, mxx: 0.0}

  defp ols_remove(%{size: n, mx: mx, my: my} = o, x, y) do
    n0 = n - 1
    mx0 = (n * mx - x) / n0
    my0 = (n * my - y) / n0

    %{
      o
      | size: n0,
        mx: mx0,
        my: my0,
        cxy: o.cxy - (x - mx0) * (y - my),
        mxx: o.mxx - (x - mx0) * (x - mx)
    }
  end

  defp ols_resync(%{points: points} = o) do
    pairs = points |> :queue.to_list() |> Enum.map(&elem(&1, 2))
    n = length(pairs)

    if n == 0 do
      %{o | mx: 0.0, my: 0.0, cxy: 0.0, mxx: 0.0}
    else
      mx = pairs |> Enum.map(&elem(&1, 0)) |> Enum.sum() |> Kernel./(n)
      my = pairs |> Enum.map(&elem(&1, 1)) |> Enum.sum() |> Kernel./(n)

      {cxy, mxx} =
        Enum.reduce(pairs, {0.0, 0.0}, fn {x, y}, {c, v} ->
          dx = x - mx
          {c + dx * (y - my), v + dx * dx}
        end)

      %{o | mx: mx, my: my, cxy: cxy, mxx: mxx}
    end
  end
end
