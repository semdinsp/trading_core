defmodule TradingCore.Options.Skew do
  @moduledoc """
  Pure arithmetic behind trading_signal's option-skew signals for SPY/QQQ:
  which monthly expiry to read, which strikes to hold, whether a leg's
  quote can be trusted, and the two measures built from those legs:

    * the ATM put−call IV spread (`atm_put_call_spread/5`);
    * the 25-delta risk reversal, put IV minus call IV at |Δ| = 0.25
      (`risk_reversal/5`).

  Floats in, floats out. No processes, no `Repo`, no clock: `now` is
  always passed in. trading_signal owns the IBKR subscriptions; this
  module only decides what to subscribe to and what the ticks mean.

  ## Units

  IBKR's `implied_vol` is a fraction (0.21 = 21 vol points), and every
  measure here is a difference of two of them, so `0.012` reads as 1.2
  vol points.

  ## A leg

  A plain map with `:strike` and `:right` (`"C"`/`"P"`) and, once ticks
  arrive, `:bid`, `:ask`, `:quote_at`, `:delayed`, `:iv`, `:delta`,
  `:und`, `:model_at`. `usable?/3` decides whether it may feed a value.
  """

  alias TradingCore.Options.ContractSelection

  @type leg :: map()
  @type bracket :: {float(), float()}

  # z such that N(z) = 0.75, for the default 25-delta target.
  @z_25 0.6744897501960817

  # A monthly is 4-5 weeks after the previous one, so this many months
  # ahead covers any DTE range a caller could sensibly ask for (up to
  # ~150 days).
  @months_ahead 6

  ## ---------------------------------------------------------------------
  ## Expiry and strikes
  ## ---------------------------------------------------------------------

  @doc """
  The monthly expiry to read on `today`: the one whose days-to-expiry
  falls in `min_dte..max_dte`, or, when none does (monthlies are 4-5 weeks
  apart, so a 15-day range can miss), the one closest to that range. Ties
  go to the longer-dated one. Only expiries strictly after `today` count.

  A monthly is the third Friday, or the Thursday before it when that
  Friday is a market holiday (`ContractSelection.monthly_expiry/1`).

      iex> TradingCore.Options.Skew.select_expiry(~D[2026-11-26], 30, 45)
      ~D[2027-01-15]
  """
  @spec select_expiry(Date.t(), pos_integer(), pos_integer()) :: Date.t()
  def select_expiry(%Date{} = today, min_dte, max_dte) when min_dte <= max_dte do
    today
    |> monthlies()
    |> Enum.filter(&(Date.diff(&1, today) > 0))
    |> Enum.min_by(fn expiry ->
      dte = Date.diff(expiry, today)
      {max(min_dte - dte, 0) + max(dte - max_dte, 0), -dte}
    end)
  end

  defp monthlies(%Date{year: year, month: month}) do
    for offset <- 0..(@months_ahead - 1) do
      total = month - 1 + offset
      first = Date.new!(year + div(total, 12), rem(total, 12) + 1, 1)

      first
      |> ContractSelection.third_friday_on_or_after(0)
      |> ContractSelection.monthly_expiry()
    end
  end

  @doc "Calendar days from `today` to `expiry`, in years (at least one day)."
  @spec years_to_expiry(Date.t(), Date.t()) :: float()
  def years_to_expiry(%Date{} = expiry, %Date{} = today),
    do: max(Date.diff(expiry, today), 1) / 365

  @doc """
  The two grid strikes either side of `x`: `{lo, hi}` with
  `lo <= x < hi`, rounded to 2 dp. A value on the grid is its own `lo`,
  even when float division puts it a hair below (7.7 / 0.1 = 76.999…).
  """
  @spec bracket(number(), number()) :: bracket()
  def bracket(x, step) do
    q = x / step
    rounded = Float.round(q)
    n = if abs(q - rounded) < 1.0e-9, do: rounded, else: Float.floor(q)

    {Float.round(n * step, 2), Float.round((n + 1) * step, 2)}
  end

  @doc """
  The strike whose Black-Scholes delta is `delta` in absolute value, for a
  put (`"P"`) or a call (`"C"`), from spot, IV and time in years. The
  forward is taken as spot and rates as zero: at 30-45 days the error is a
  fraction of one strike step, and the live deltas decide the final
  bracket anyway (`wing_bracket/3`).

      put:  K = S·exp(−z·σ√T + σ²T/2)
      call: K = S·exp(+z·σ√T + σ²T/2)
      z = N⁻¹(1 − delta)
  """
  @spec target_strike(number(), number(), number(), String.t(), number()) :: float()
  def target_strike(spot, iv, t, right, delta \\ 0.25) when right in ["P", "C"] do
    z = if delta == 0.25, do: @z_25, else: inverse_normal(1 - delta)
    sd = iv * :math.sqrt(t)
    drift = iv * iv * t / 2
    sign = if right == "P", do: -1, else: 1

    spot * :math.exp(sign * z * sd + drift)
  end

  # Bisection on erf: 80 halvings of [-8, 8] is well below float
  # resolution. Only used for a non-default delta.
  defp inverse_normal(p) do
    {lo, hi} =
      Enum.reduce(1..80, {-8.0, 8.0}, fn _, {lo, hi} ->
        mid = (lo + hi) / 2
        if normal_cdf(mid) < p, do: {mid, hi}, else: {lo, mid}
      end)

    (lo + hi) / 2
  end

  defp normal_cdf(x), do: 0.5 * (1 + :math.erf(x / :math.sqrt(2)))

  ## ---------------------------------------------------------------------
  ## Leg quality
  ## ---------------------------------------------------------------------

  @doc """
  Whether `leg` may feed a value at `now`: `unusable_reason/3` is `nil`.

  IBKR sends a quote only when it changes, so `stale_ms` is how long a
  quiet quote is still believed. Near-the-money SPY/QQQ monthlies
  re-quote with every move in the underlying, so a couple of minutes of
  silence in session means the feed stopped, not the market.
  """
  @spec usable?(leg() | nil, DateTime.t(), pos_integer()) :: boolean()
  def usable?(leg, now, stale_ms), do: unusable_reason(leg, now, stale_ms) == nil

  @doc """
  Why `leg` is not usable at `now`, or `nil` when it is. The first
  failing check, in this order:

    * `:no_leg` — `nil`;
    * `:no_two_sided_quote` — `bid` or `ask` is not a number `> 0`;
    * `:crossed` — `bid > ask` (locked, `bid == ask`, is fine);
    * `:delayed` — `delayed: true`, a delayed-data fallback;
    * `:stale_quote` — `quote_at` missing or older than `stale_ms`;
    * `:stale_model` — `model_at` missing or older than `stale_ms`;
    * `:no_iv` — `iv` not a number in (0, 5) (IBKR sends sentinels when
      it can't compute one);
    * `:no_delta` — `delta` not a number, `0`, or `|delta| > 1`.
  """
  @spec unusable_reason(leg() | nil, DateTime.t(), pos_integer()) :: atom() | nil
  def unusable_reason(nil, _now, _stale_ms), do: :no_leg

  def unusable_reason(leg, now, stale_ms) do
    cond do
      not (positive?(leg[:bid]) and positive?(leg[:ask])) -> :no_two_sided_quote
      leg[:bid] > leg[:ask] -> :crossed
      leg[:delayed] == true -> :delayed
      not fresh?(leg[:quote_at], now, stale_ms) -> :stale_quote
      not fresh?(leg[:model_at], now, stale_ms) -> :stale_model
      not valid_iv?(leg[:iv]) -> :no_iv
      not valid_delta?(leg[:delta]) -> :no_delta
      true -> nil
    end
  end

  defp valid_iv?(iv), do: is_number(iv) and iv > 0 and iv < 5
  defp valid_delta?(delta), do: is_number(delta) and delta != 0 and abs(delta) <= 1
  defp positive?(x), do: is_number(x) and x > 0

  defp fresh?(%DateTime{} = at, now, stale_ms),
    do: DateTime.diff(now, at, :millisecond) <= stale_ms

  defp fresh?(_at, _now, _stale_ms), do: false

  ## ---------------------------------------------------------------------
  ## Measures
  ## ---------------------------------------------------------------------

  @doc """
  ATM put IV minus ATM call IV at whichever of `[lo, hi]` is nearest
  `spot` (a tie goes to the lower strike), from the legs in `legs` (a map
  whose keys are opaque, e.g. OCC symbols).

  `{:error, {:put | :call, strike, reason}}` when that strike's put or
  call is not usable (the put is reported first). There is no fallback to
  the other strike, so the series never mixes strikes within a minute
  because one quote went quiet.
  """
  @spec atm_put_call_spread(
          %{optional(any()) => leg()},
          number(),
          [number()],
          DateTime.t(),
          pos_integer()
        ) ::
          {:ok, float()} | {:error, {:put | :call, number(), atom()}}
  def atm_put_call_spread(legs, spot, [_lo, _hi] = strikes, now, stale_ms) do
    strike = Enum.min_by(strikes, &{abs(&1 - spot), &1})
    put = find_leg(legs, strike, "P")
    call = find_leg(legs, strike, "C")

    case {unusable_reason(put, now, stale_ms), unusable_reason(call, now, stale_ms)} do
      {nil, nil} -> {:ok, put.iv - call.iv}
      {nil, reason} -> {:error, {:call, strike, reason}}
      {reason, _} -> {:error, {:put, strike, reason}}
    end
  end

  defp find_leg(legs, strike, right) do
    Enum.find_value(legs, fn {_key, leg} ->
      if leg.strike == strike and leg.right == right, do: leg
    end)
  end

  @doc """
  IV at `target` absolute delta, interpolated linearly in |delta| between
  the two legs of one wing. The ends are inclusive. `{:error,
  :outside_bracket}` when `target` is not between their |delta|s, or when
  the two |delta|s are equal and differ from `target` (the caller
  re-centres the wing).
  """
  @spec iv_at_delta([leg()], number()) :: {:ok, float()} | {:error, :outside_bracket}
  def iv_at_delta([a, b], target) do
    [{d_lo, iv_lo}, {d_hi, iv_hi}] = Enum.sort([{abs(a.delta), a.iv}, {abs(b.delta), b.iv}])

    cond do
      d_lo == target ->
        {:ok, iv_lo}

      d_hi == target ->
        {:ok, iv_hi}

      d_lo < target and target < d_hi ->
        {:ok, iv_lo + (iv_hi - iv_lo) * (target - d_lo) / (d_hi - d_lo)}

      true ->
        {:error, :outside_bracket}
    end
  end

  @doc """
  `target`-delta put IV minus call IV (the risk reversal; 25-delta when
  `target` is `0.25`), from each wing's two legs. Each wing is a
  two-element list that may contain `nil` while a leg is still unknown.

  `{:error, {:put | :call, reason}}` with the first unusable leg's
  `unusable_reason/3`, or `:outside_bracket` when a wing's deltas don't
  straddle `target`. The put wing is checked first.
  """
  @spec risk_reversal([leg() | nil], [leg() | nil], number(), DateTime.t(), pos_integer()) ::
          {:ok, float()} | {:error, {:put | :call, atom()}}
  def risk_reversal(put_legs, call_legs, target, now, stale_ms) do
    with {:ok, put_iv} <- wing_iv(:put, put_legs, target, now, stale_ms),
         {:ok, call_iv} <- wing_iv(:call, call_legs, target, now, stale_ms) do
      {:ok, put_iv - call_iv}
    end
  end

  defp wing_iv(side, [_, _] = legs, target, now, stale_ms) do
    with nil <- Enum.find_value(legs, &unusable_reason(&1, now, stale_ms)),
         {:ok, iv} <- iv_at_delta(legs, target) do
      {:ok, iv}
    else
      {:error, reason} -> {:error, {side, reason}}
      reason -> {:error, {side, reason}}
    end
  end

  defp wing_iv(side, _legs, _target, _now, _stale_ms), do: {:error, {side, :no_leg}}

  ## ---------------------------------------------------------------------
  ## Which strikes to hold
  ## ---------------------------------------------------------------------

  @doc """
  The bracket one wing should hold next. `ctx` is
  `%{now, stale_ms, iv_seed, spot, t, right, delta, step}`.

    * `current == nil`: aim at `target_strike/5` from `ctx.iv_seed`.
    * Both legs usable and their |delta|s straddle `ctx.delta`: keep
      `current`.
    * Both usable but outside: re-aim from the mean of the two legs' IVs.
      When that lands on `current` again (the BS strike disagrees with the
      live deltas), step one grid step toward the target instead, so the
      wing can't stick on a bracket that will never straddle it: a put's
      |Δ| rises with strike, a call's falls.
    * Otherwise (a leg missing or not yet usable): keep `current`, the
      legs are waiting for ticks.
  """
  @spec wing_bracket(bracket() | nil, [leg() | nil], map()) :: bracket()
  def wing_bracket(nil, _legs, ctx), do: aim(ctx.iv_seed, ctx)

  def wing_bracket(current, legs, %{} = ctx) do
    usable = Enum.filter(legs, &usable?(&1, ctx.now, ctx.stale_ms))

    with [_, _] <- usable,
         {:error, :outside_bracket} <- iv_at_delta(usable, ctx.delta) do
      mean_iv = (Enum.at(usable, 0).iv + Enum.at(usable, 1).iv) / 2

      case aim(mean_iv, ctx) do
        ^current -> nudge(current, usable, ctx)
        aimed -> aimed
      end
    else
      _ -> current
    end
  end

  defp aim(iv, ctx) do
    ctx.spot
    |> target_strike(iv, ctx.t, ctx.right, ctx.delta)
    |> bracket(ctx.step)
  end

  # Both |Δ| are on the same side of the target (or equal to each other).
  # Below the target, a put needs a higher strike and a call a lower one.
  defp nudge({lo, hi}, usable, ctx) do
    below? = Enum.all?(usable, &(abs(&1.delta) < ctx.delta))
    up? = below? == (ctx.right == "P")
    shift = if up?, do: ctx.step, else: -ctx.step

    {Float.round(lo + shift, 2), Float.round(hi + shift, 2)}
  end

  @doc """
  The ATM bracket: `current` while `lo <= spot <= hi`, otherwise the grid
  bracket around `spot`.
  """
  @spec atm_bracket(bracket() | nil, number(), number()) :: bracket()
  def atm_bracket({lo, hi} = current, spot, _step) when spot >= lo and spot <= hi, do: current
  def atm_bracket(_current, spot, step), do: bracket(spot, step)
end
