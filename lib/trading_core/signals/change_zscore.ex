defmodule TradingCore.Signals.ChangeZscore do
  @moduledoc """
  The z-score of an N-minute change against the same change over a
  trailing lookback, on a series sampled once a minute. Backs
  trading_signal's skew-change signal (the 60-minute change in the 25Δ
  risk reversal against the last 7 days of 60-minute changes).

  Pure. `samples` is a map `%{minute_key => float}` with
  `minute_key = unix_seconds div 60`; gaps are allowed, and a change is
  only defined where both its end keys exist exactly. There is no
  overnight special-casing: the series is only sampled in session, so the
  first `window_min` minutes of a session simply have no change. The
  caller keeps the map bounded with `prune/3`.
  """

  @type samples :: %{optional(integer()) => float()}

  # Same degenerate-variance floor as TradingCore.Signals' zscore (see
  # the calibration note there): stdev below max(1e-12, 1e-6 x scale)
  # is float jitter, not a spread.
  @degenerate_stdev_ratio 1.0e-6
  @degenerate_stdev_absolute 1.0e-12

  @doc """
  `samples[minute] - samples[minute - window_min]`, or `nil` when either
  key is missing.
  """
  @spec change(samples(), integer(), pos_integer()) :: float() | nil
  def change(samples, minute, window_min) do
    case {Map.fetch(samples, minute), Map.fetch(samples, minute - window_min)} do
      {{:ok, now}, {:ok, before}} -> now - before
      _ -> nil
    end
  end

  @doc """
  The z-score of the current change, `change(samples, minute,
  window_min)`, against the reference set: every defined
  `change(samples, m, window_min)` for `m` in `[minute - lookback_min,
  minute)` (the current minute excluded). `z = (c - mean) / stdev`, using
  the sample standard deviation.

    * `{:error, :no_change}` — the current change is undefined;
    * `{:error, :warming_up}` — fewer than `min_samples` reference
      changes (and always fewer than 2);
    * `{:error, :flat}` — `stdev < max(1e-12, 1e-6 * max(|mean|, |c|))`.
  """
  @spec zscore(samples(), integer(), pos_integer(), pos_integer(), pos_integer()) ::
          {:ok, float()} | {:error, :no_change | :warming_up | :flat}
  def zscore(samples, minute, window_min, lookback_min, min_samples) do
    case change(samples, minute, window_min) do
      nil ->
        {:error, :no_change}

      c ->
        reference = reference_changes(samples, minute, window_min, lookback_min)
        n = length(reference)

        if n < max(min_samples, 2), do: {:error, :warming_up}, else: score(c, reference, n)
    end
  end

  defp score(c, reference, n) do
    mean = Enum.sum(reference) / n
    variance = Enum.reduce(reference, 0.0, &(&2 + (&1 - mean) ** 2)) / (n - 1)
    stdev = :math.sqrt(variance)
    floor = max(@degenerate_stdev_absolute, @degenerate_stdev_ratio * max(abs(mean), abs(c)))

    if stdev < floor, do: {:error, :flat}, else: {:ok, (c - mean) / stdev}
  end

  defp reference_changes(samples, minute, window_min, lookback_min) do
    for m <- (minute - lookback_min)..(minute - 1)//1,
        c = change(samples, m, window_min),
        c != nil,
        do: c
  end

  @doc """
  Drops every key older than `minute - keep_min`. Pass `lookback_min +
  window_min` to keep exactly what `zscore/5` reads.
  """
  @spec prune(samples(), integer(), non_neg_integer()) :: samples()
  def prune(samples, minute, keep_min) do
    cutoff = minute - keep_min
    Map.filter(samples, fn {key, _value} -> key >= cutoff end)
  end
end
