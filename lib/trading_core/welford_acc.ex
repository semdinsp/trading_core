defmodule TradingCore.WelfordAcc do
  @moduledoc """
  Welford's online mean/variance algorithm — lets a signal type maintain a
  rolling mean/variance over a window of samples without ever needing to
  keep every sample in memory just to compute one, only the running
  `{count, mean, m2}`.

  Moved verbatim from `trading_signal`'s `TradingSignal.Signals.WelfordAcc`
  into this shared library (own file, matching how `trading_core` already
  keeps `TradingCore.MarketHours.Session` as its own file next to
  `TradingCore.MarketHours`) — this module was already 100% pure with zero
  I/O, so the move is a straight relocation, not a rewrite. It's the shared
  primitive `TradingCore.Signals.self_zscore/5` and
  `TradingCore.Signals.spread_zscore/6` both build on (see either
  function's own docs for how it rebuilds `t()` from a trimmed window on
  every tick, and why: `trim_window/3` can drop arbitrarily many stale
  samples in one step, and Welford's algorithm has no cheap "remove a
  batch of old samples" operation, only "add one more").

  Living in `trading_core` — rather than staying `trading_signal`-only —
  is what lets a future backtest replay engine compute the exact same
  rolling mean/variance over historical data that `trading_signal`
  computes live, using this exact code, unchanged.
  """

  defstruct count: 0, mean: 0.0, m2: 0.0

  @type t :: %__MODULE__{count: non_neg_integer(), mean: float(), m2: float()}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec add(t(), float()) :: t()
  def add(%__MODULE__{count: count, mean: mean, m2: m2}, sample) do
    count = count + 1
    delta = sample - mean
    mean = mean + delta / count
    delta2 = sample - mean
    m2 = m2 + delta * delta2

    %__MODULE__{count: count, mean: mean, m2: m2}
  end

  @spec variance(t()) :: float()
  def variance(%__MODULE__{count: count}) when count < 2, do: 0.0
  def variance(%__MODULE__{count: count, m2: m2}), do: m2 / (count - 1)
end
