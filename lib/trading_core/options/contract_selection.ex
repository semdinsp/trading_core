defmodule TradingCore.Options.ContractSelection do
  @moduledoc """
  Turns an `option_leg_config` into the ordered list of concrete option
  contracts to try, so `trading_options_sim` and `trading_live` pick the
  same contract from the same inputs.

  Ported from the pure parts of `TradingOptionsSim.ContractSelector` (and
  the literal `fixed_strike` resolution in
  `TradingOptionsSim.SimActivator.resolve_contract_template/1`). This
  module does no IO. Each app keeps its own hub calls: it looks up spot,
  calls `candidates/4`, and walks the list with
  `TradingHub.IBKR.ContractResolver.resolve/4` until one contract
  resolves. If none does, that's `:no_listed_contract`, and the app must
  not trade a guess.

  ## `today` is the caller's ET trading date

  Every function that needs a date takes `today` as an argument and
  never reads the clock. Pass the **America/New_York trading date**, not
  `Date.utc_today/0`, which moves to tomorrow at 8pm ET (7pm in winter)
  and would shift a `dte_target` expiry by a day in the evening.
  trading_live and trading_options_sim agreed on this.

  ## Rounding first, probing only to confirm

  A resolve that hits costs ~148ms, but a miss costs a full 10 seconds:
  IBKR never replies for a contract it doesn't know. The hub client is
  also a single process shared by everything in an app, so an unbounded
  probe loop blocks every other hub call behind it. The strike is
  therefore ROUNDED to the underlying's known grid (`strike_increment/1`)
  and confirmed with one resolve, and the candidate list is short
  (at most 5).

  The increments are a real assumption, verified against IBKR on
  2026-09-20 for the liquid monthlies:

      SPY  760C ok, 762C/763C not found            -> 5.0
      QQQ  715C/720C ok                            -> 5.0
      XLF   53C ok,  53.5C not found,  54C ok      -> 1.0
      XLK  275C ok, 276C/277.5C/280C not found     -> UNRESOLVED

  XLK is deliberately left out: no single increment fits, so it takes the
  $1 default and will most likely fail with `:no_listed_contract` until
  measured properly. No contract beats a wrong one. $1 is the default
  because it's the densest common grid, so an unknown symbol misses
  rather than skipping past a strike that exists.

  ## Expiry

  `"dte_target"` picks the nearest **third Friday** (the standard
  monthly expiry: the most liquid, and every listed underlying has one)
  on or after `today + dte_target` (default 45 days), then the next two
  third Fridays as fall-through. When a third Friday is a market holiday
  (Good Friday, Juneteenth), that month expires on the Thursday before,
  and the candidate is that Thursday (`monthly_expiry/1`). That fall-through is not hypothetical:
  on 2026-09-23 SPY listed Dec, Jan and Mar but not Feb 2027, so every
  120-DTE SPY leg (target 20270219) failed until the next months were
  tried.

  A `"fixed_expiry"` never falls through. It's a deliberate choice (a
  specific LEAPS, say), and trading a different month would be worse than
  not trading.

  ## Supported configs

  Mirrors what trading_options_sim accepts today:

    * `"strike_selection" => "atm_offset"` with `"right"` `"C"`/`"P"`,
      optional `"strike_offset"` (dollars, default 0), and either
      `"expiry_selection" => "dte_target"` (optional `"dte_target"`,
      default 45) or a `"fixed_expiry"` (`"YYYYMMDD"`).
    * `"strike_selection" => "fixed_strike"` with `"expiry_selection"`
      `"fixed"` or `"leaps"` (the sim treats them identically; `"leaps"`
      is documentation), `"fixed_expiry"`, `"fixed_strike"` (a number or
      a string such as `"762.00"`) and `"right"` `"C"`/`"P"`. This gives
      exactly one candidate.

  Anything else, including `"right" => "either"`, returns
  `{:error, :unsupported_leg_config}`.
  """

  alias TradingCore.MarketHours

  @type contract :: %{expiry: String.t(), strike: float(), right: String.t()}

  # Strike grid per underlying; see the moduledoc for how each was
  # measured and why XLK is absent.
  @strike_increments %{"SPY" => 5.0, "QQQ" => 5.0, "XLF" => 1.0}
  @default_increment 1.0

  @default_dte_target 45

  @doc """
  The ordered contracts to try for `symbol` under `config`, given the
  underlying's `spot` and the caller's ET trading date `today`.

  For `"atm_offset"`, the target is `spot + strike_offset`, rounded to
  `strike_increment(symbol)`. The rounded strike comes first on each
  expiry candidate in order, then one grid step above and below on the
  FIRST expiry only. The order matters because every miss costs 10s. On
  a $5 grid the rounded strike is essentially always listed, so a miss
  on it almost always means the month is missing; trying neighbours on a
  missing month first would spend 30s learning nothing.

  For `"fixed_strike"`, it's the one literal contract, and `spot` is
  ignored (it may be `nil`).

  `strike` is a float rounded to 2 decimals. trading_options_sim stores
  it as `value |> Decimal.from_float() |> Decimal.round(2)`.
  """
  @spec candidates(String.t(), map(), number() | nil, Date.t()) ::
          {:ok, [contract()]} | {:error, :unsupported_leg_config | :no_spot}
  def candidates(symbol, %{"strike_selection" => "atm_offset"} = config, spot, today) do
    with {:ok, right} <- fetch_right(config),
         {:ok, offset} <- fetch_offset(config),
         {:ok, expiries} <- expiry_candidates(config, today),
         :ok <- check_spot(spot) do
      increment = strike_increment(symbol)
      rounded = round_to_grid(spot + offset, increment)
      [first | _] = expiries

      neighbours =
        [rounded + increment, rounded - increment]
        |> Enum.map(&{first, Float.round(&1, 2)})

      contracts =
        (Enum.map(expiries, &{&1, rounded}) ++ neighbours)
        |> Enum.uniq()
        |> Enum.map(fn {expiry, strike} -> %{expiry: expiry, strike: strike, right: right} end)

      {:ok, contracts}
    end
  end

  def candidates(
        _symbol,
        %{
          "strike_selection" => "fixed_strike",
          "expiry_selection" => expiry_selection,
          "fixed_expiry" => expiry,
          "fixed_strike" => strike
        } = config,
        _spot,
        _today
      )
      when expiry_selection in ["fixed", "leaps"] and is_binary(expiry) do
    with {:ok, right} <- fetch_right(config),
         {:ok, strike} <- parse_strike(strike) do
      {:ok, [%{expiry: expiry, strike: strike, right: right}]}
    end
  end

  def candidates(_symbol, _config, _spot, _today), do: {:error, :unsupported_leg_config}

  @doc """
  The expiries to try, as `"YYYYMMDD"`, in order.

  `"dte_target"`: the third Friday on or after `today + dte_target`
  (default #{@default_dte_target}), then the next two third Fridays.
  Otherwise a `"fixed_expiry"` alone, which never falls through.
  """
  @spec expiry_candidates(map(), Date.t()) ::
          {:ok, [String.t()]} | {:error, :unsupported_leg_config}
  def expiry_candidates(%{"expiry_selection" => "dte_target"} = config, today) do
    case Map.get(config, "dte_target") || @default_dte_target do
      dte when is_integer(dte) and dte >= 0 ->
        first = third_friday_on_or_after(today, dte)
        second = third_friday_on_or_after(first, 1)
        third = third_friday_on_or_after(second, 1)
        {:ok, Enum.map([first, second, third], &(&1 |> monthly_expiry() |> wire_format()))}

      _invalid ->
        {:error, :unsupported_leg_config}
    end
  end

  def expiry_candidates(%{"fixed_expiry" => expiry}, _today) when is_binary(expiry),
    do: {:ok, [expiry]}

  def expiry_candidates(_config, _today), do: {:error, :unsupported_leg_config}

  @doc """
  The nearest third Friday (the Friday falling on day 15..21) on or after
  `date + dte` days.
  """
  @spec third_friday_on_or_after(Date.t(), non_neg_integer()) :: Date.t()
  def third_friday_on_or_after(date, dte) do
    date
    |> Date.add(dte)
    |> Stream.iterate(&Date.add(&1, 1))
    |> Enum.find(&third_friday?/1)
  end

  @doc """
  The standard monthly expiry for the month whose third Friday is
  `third_friday`: that Friday, or the Thursday before it when the Friday
  is a US equities market holiday. On 2026-06-19 (Juneteenth, a third
  Friday) the June monthly expires 20260618; probing 20260619 would cost
  a 10s miss and fall through to July, a month longer-dated than asked.

  Holidays come from `TradingCore.MarketHours.holiday?/2`, a hardcoded
  calendar. For a year it doesn't list yet, this returns the Friday, as
  before this check existed.
  """
  @spec monthly_expiry(Date.t()) :: Date.t()
  def monthly_expiry(third_friday) do
    if MarketHours.holiday?("US_EQUITIES", third_friday),
      do: Date.add(third_friday, -1),
      else: third_friday
  end

  @doc """
  The strike grid for `symbol`: `5.0` for SPY and QQQ, `1.0` for XLF,
  and `#{@default_increment}` for anything else. See the moduledoc.
  """
  @spec strike_increment(String.t()) :: float()
  def strike_increment(symbol), do: Map.get(@strike_increments, symbol, @default_increment)

  defp third_friday?(date), do: Date.day_of_week(date) == 5 and date.day in 15..21

  defp wire_format(date), do: Calendar.strftime(date, "%Y%m%d")

  # Float.round/1 rounds half away from zero, so 767.5 on a $5 grid is
  # 770.0. Same arithmetic as trading_options_sim, deliberately.
  defp round_to_grid(target, increment),
    do: Float.round(Float.round(target / increment) * increment, 2)

  defp fetch_right(%{"right" => right}) when right in ["C", "P"], do: {:ok, right}
  defp fetch_right(_config), do: {:error, :unsupported_leg_config}

  defp fetch_offset(config) do
    case Map.get(config, "strike_offset") || 0 do
      offset when is_number(offset) -> {:ok, offset}
      _invalid -> {:error, :unsupported_leg_config}
    end
  end

  # Nothing to be at-the-money of.
  defp check_spot(spot) when is_number(spot) and spot > 0, do: :ok
  defp check_spot(_spot), do: {:error, :no_spot}

  # Parsed through Decimal like trading_options_sim's
  # Decimal.new(to_string(strike)), so "762.00", 762 and 762.0 agree.
  defp parse_strike(strike) when is_number(strike) or is_binary(strike) do
    case Decimal.parse(to_string(strike)) do
      {decimal, ""} -> {:ok, decimal |> Decimal.round(2) |> Decimal.to_float()}
      _invalid -> {:error, :unsupported_leg_config}
    end
  end

  defp parse_strike(_strike), do: {:error, :unsupported_leg_config}
end
