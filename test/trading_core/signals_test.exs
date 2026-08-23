defmodule TradingCore.SignalsTest do
  use ExUnit.Case, async: true

  alias TradingCore.Signals
  alias TradingCore.WelfordAcc

  @base ~U[2026-01-01 09:30:00.000000Z]

  describe "derivative/4" do
    test "a single sample produces no value yet" do
      {history, value} = Signals.derivative([], Decimal.new(10), @base)

      assert value == nil
      assert [{@base, stored}] = history
      assert Decimal.equal?(stored, Decimal.new(10))
    end

    test "slope of a known linear sequence matches the hand-computed rate" do
      # 10 -> 20 over exactly 2 seconds => slope of 5 units/second.
      t0 = @base
      t1 = DateTime.add(@base, 2, :second)

      {history, nil} = Signals.derivative([], Decimal.new(10), t0)
      {_history, value} = Signals.derivative(history, Decimal.new(20), t1)

      assert Decimal.equal?(value, Decimal.new("5.00000000"))
    end

    test "falling values produce a negative slope" do
      t0 = @base
      t1 = DateTime.add(@base, 1, :second)

      {history, nil} = Signals.derivative([], Decimal.new(20), t0)
      {_history, value} = Signals.derivative(history, Decimal.new(10), t1)

      assert Decimal.compare(value, 0) == :lt
      assert Decimal.equal?(value, Decimal.new("-10.00000000"))
    end

    test "zero elapsed time between newest and oldest produces no value" do
      {history, nil} = Signals.derivative([], Decimal.new(10), @base)
      {_history, value} = Signals.derivative(history, Decimal.new(20), @base)

      assert value == nil
    end

    test "an exact-precision division result is rounded to the default precision (8)" do
      t0 = @base
      t1 = DateTime.add(@base, 1, :second)

      {history, _} = Signals.derivative([], Decimal.new("10.00000000001"), t0)
      {_history, value} = Signals.derivative(history, Decimal.new("20.00000000003"), t1)

      assert Decimal.scale(value) <= 8
    end

    test "history entries are rounded to the default precision as they're stored" do
      {history, _value} = Signals.derivative([], Decimal.new("1.123456789123"), @base)
      assert [{@base, stored}] = history
      assert Decimal.scale(stored) <= 8
    end

    test "history is capped at max_history_samples even when every tick is within the window" do
      # Every tick lands at the same `now` (mirroring the live regression
      # this guards against: this process itself falling behind its own
      # mailbox, so DateTime.utc_now/0 barely advances between ticks) —
      # the time-based trim alone would keep unbounded history here, so
      # only the hard @max_history_samples cap can be shrinking it.
      final_history =
        Enum.reduce(1..1000, [], fn i, history ->
          {new_history, _value} = Signals.derivative(history, Decimal.new(100 + i), @base)
          new_history
        end)

      assert length(final_history) == 500
    end

    test "custom precision/window_ms options are honored" do
      t0 = @base
      t1 = DateTime.add(@base, 1, :second)

      {history, _} = Signals.derivative([], Decimal.new(10), t0, precision: 2)
      {_history, value} = Signals.derivative(history, Decimal.new(20), t1, precision: 2)

      assert Decimal.scale(value) <= 2
    end
  end

  describe "vwap/3" do
    test "matches a hand-computed weighted average of known price/volume pairs" do
      # 100 shares @ 10.00 + 200 shares @ 13.00 => (1000 + 2600) / 300 = 12.0
      cum_pv =
        Decimal.new(0)
        |> Signals.fold_price_weighted_delta(Decimal.new("10.00"), Decimal.new(100))

      cum_pv = Signals.fold_price_weighted_delta(cum_pv, Decimal.new("13.00"), Decimal.new(200))

      value = Signals.vwap(cum_pv, Decimal.new(300))
      assert Decimal.equal?(value, Decimal.new("12.00000000"))
    end

    test "nil when cumulative volume is zero" do
      assert Signals.vwap(Decimal.new(0), Decimal.new(0)) == nil
    end

    test "nil when cumulative volume is negative" do
      assert Signals.vwap(Decimal.new(100), Decimal.new(-5)) == nil
    end

    test "a division that doesn't divide evenly is rounded to the default precision" do
      value = Signals.vwap(Decimal.new("123456.789"), Decimal.new(1166))
      assert Decimal.scale(value) <= 8
    end
  end

  describe "fold_price_weighted_delta/3" do
    test "adds last_price * delta to cum_pv" do
      result =
        Signals.fold_price_weighted_delta(Decimal.new(1000), Decimal.new("101.0"), Decimal.new(500))

      assert Decimal.equal?(result, Decimal.new("51500.0"))
    end

    test "no-op when last_price is nil" do
      assert Signals.fold_price_weighted_delta(Decimal.new(1000), nil, Decimal.new(500)) ==
               Decimal.new(1000)
    end

    test "no-op when delta is nil" do
      assert Signals.fold_price_weighted_delta(Decimal.new(1000), Decimal.new("101.0"), nil) ==
               Decimal.new(1000)
    end
  end

  describe "self_zscore/5" do
    test "no value until at least 2 samples are in the window" do
      {history, welford, value} =
        Signals.self_zscore([], WelfordAcc.new(), Decimal.new(10), @base)

      assert value == nil
      assert length(history) == 1
      assert welford.count == 1
    end

    test "zscore matches the textbook formula for a small known sample set" do
      # Reuse the same sample set as WelfordAccTest's textbook case:
      # mean = 5.0, sample variance (n-1) = 32/7, stdev = sqrt(32/7).
      samples = [2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0]

      {final_history, final_welford, final_value} =
        samples
        |> Enum.with_index()
        |> Enum.reduce({[], WelfordAcc.new(), nil}, fn {sample, i}, {history, welford, _value} ->
          Signals.self_zscore(
            history,
            welford,
            Decimal.from_float(sample),
            DateTime.add(@base, i, :second)
          )
        end)

      assert length(final_history) == 8
      assert_in_delta final_welford.mean, 5.0, 0.0001

      expected_stdev = :math.sqrt(32 / 7)
      expected_z = (9.0 - 5.0) / expected_stdev

      assert_in_delta Decimal.to_float(final_value), expected_z, 0.0001
    end

    test "nil when the window has zero variance (a flat value)" do
      {history, welford, _} = Signals.self_zscore([], WelfordAcc.new(), Decimal.new(10), @base)

      {_history, _welford, value} =
        Signals.self_zscore(history, welford, Decimal.new(10), DateTime.add(@base, 1, :second))

      assert value == nil
    end

    test "history is capped at max_history_samples" do
      # Same fixed-`now` shape as Derivative's identically-named test — all
      # ticks land within the time window, so only the hard cap can be
      # shrinking history.
      {final_history, _welford, _value} =
        Enum.reduce(1..1000, {[], WelfordAcc.new(), nil}, fn i, {history, welford, _value} ->
          Signals.self_zscore(history, welford, Decimal.new(100 + i), @base)
        end)

      assert length(final_history) == 500
    end
  end

  describe "percent_deviation/2" do
    test "matches a hand-computed relative difference" do
      # value 103.5 vs reference 100 => 3.5% above.
      value = Signals.percent_deviation(Decimal.new("103.5"), Decimal.new("100"))
      assert Decimal.equal?(value, Decimal.new("3.5"))
    end

    test "negative when value is below reference" do
      value = Signals.percent_deviation(Decimal.new("95"), Decimal.new("100"))
      assert Decimal.equal?(value, Decimal.new("-5.0"))
    end

    test "nil when reference is zero" do
      assert Signals.percent_deviation(Decimal.new("10"), Decimal.new("0")) == nil
    end
  end

  describe "ratio/3" do
    test "matches a hand-computed quotient" do
      value = Signals.ratio(Decimal.new("50"), Decimal.new("20"))
      assert Decimal.equal?(value, Decimal.new("2.50000000"))
    end

    test "nil when reference is zero" do
      assert Signals.ratio(Decimal.new("10"), Decimal.new("0")) == nil
    end
  end

  describe "spread_zscore/6" do
    test "computes the spread and its zscore against the spread's own rolling history" do
      # value/reference pairs whose spreads are exactly the textbook sample
      # set [2, 4, 4, 4, 5, 5, 7, 9] used above (reference held at 0).
      spreads = [2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0]

      {_history, welford, final_value} =
        spreads
        |> Enum.with_index()
        |> Enum.reduce({[], WelfordAcc.new(), nil}, fn {spread, i}, {history, welford, _value} ->
          Signals.spread_zscore(
            history,
            welford,
            Decimal.from_float(spread),
            Decimal.new(0),
            DateTime.add(@base, i, :second)
          )
        end)

      assert_in_delta welford.mean, 5.0, 0.0001

      expected_stdev = :math.sqrt(32 / 7)
      expected_z = (9.0 - 5.0) / expected_stdev

      assert_in_delta Decimal.to_float(final_value), expected_z, 0.0001
    end

    test "no value until at least 2 samples are in the window" do
      {_history, _welford, value} =
        Signals.spread_zscore([], WelfordAcc.new(), Decimal.new(10), Decimal.new(5), @base)

      assert value == nil
    end
  end

  describe "wavelet/2" do
    test "no value until the window has 64 samples" do
      {window, value} =
        Enum.reduce(1..63, {[], nil}, fn i, {window, _value} ->
          Signals.wavelet(window, i * 1.0)
        end)

      assert value == nil
      assert length(window) == 63
    end

    test "emits a value once the window fills, same length as the input series" do
      {window, value} =
        Enum.reduce(1..64, {[], nil}, fn i, {window, _value} ->
          Signals.wavelet(window, i * 1.0)
        end)

      assert length(window) == 64
      assert %Decimal{} = value
    end

    test "window stays fixed-size (drops oldest) once full" do
      {window, _value} =
        Enum.reduce(1..70, {[], nil}, fn i, {window, _value} ->
          Signals.wavelet(window, i * 1.0)
        end)

      assert length(window) == 64
      # Oldest 6 samples (1.0..6.0) should have been dropped.
      assert List.first(window) == 7.0
      assert List.last(window) == 70.0
    end

    test "denoising a noisy series reduces total deviation from the underlying trend" do
      trend = for i <- 1..64, do: i * 0.5

      noisy =
        trend
        |> Enum.with_index()
        |> Enum.map(fn {v, i} -> v + if(rem(i, 2) == 0, do: 1.0, else: -1.0) end)

      {_window, denoised_last} =
        Enum.reduce(noisy, {[], nil}, fn sample, {window, _value} ->
          Signals.wavelet(window, sample)
        end)

      # The last point of the reconstructed series should be closer to the
      # trend's own last point than the noisy sample was.
      trend_last = List.last(trend)
      noisy_last = List.last(noisy)

      noisy_error = abs(noisy_last - trend_last)
      denoised_error = abs(Decimal.to_float(denoised_last) - trend_last)

      # Small floating-point tolerance — a single point's error can be a
      # hair above the noisy sample's own error even when denoising
      # overall helps, since VisuShrink optimizes the whole series' MSE,
      # not this one specific point.
      assert denoised_error <= noisy_error + 1.0e-6
    end
  end

  describe "donchian/4 + donchian_bands/1" do
    test "no value until at least 2 prices are in the window" do
      {prices, value} = Signals.donchian([], 100.0, @base, window_ms: :timer.minutes(20))
      assert value == nil
      assert Signals.donchian_bands(prices) == nil
    end

    test "emits +1 (breakout) when the latest price is at or above the window high" do
      {prices, nil} = Signals.donchian([], 100.0, @base, window_ms: :timer.minutes(20))

      {prices, value} =
        Signals.donchian(prices, 105.0, DateTime.add(@base, 1, :second),
          window_ms: :timer.minutes(20)
        )

      assert Decimal.equal?(value, Decimal.new(1))
      assert {upper, middle, lower} = Signals.donchian_bands(prices)
      assert Decimal.equal?(upper, Decimal.new("105.0"))
      assert Decimal.equal?(lower, Decimal.new("100.0"))
      assert Decimal.equal?(middle, Decimal.new("102.5"))
    end

    test "emits -1 (breakdown) when the latest price is at or below the window low" do
      {prices, nil} = Signals.donchian([], 100.0, @base, window_ms: :timer.minutes(20))

      {_prices, value} =
        Signals.donchian(prices, 95.0, DateTime.add(@base, 1, :second),
          window_ms: :timer.minutes(20)
        )

      assert Decimal.equal?(value, Decimal.new(-1))
    end

    test "emits 0 when the latest price is strictly inside the channel" do
      {prices, nil} = Signals.donchian([], 100.0, @base, window_ms: :timer.minutes(20))

      {prices, _value} =
        Signals.donchian(prices, 110.0, DateTime.add(@base, 1, :second),
          window_ms: :timer.minutes(20)
        )

      {_prices, value} =
        Signals.donchian(prices, 105.0, DateTime.add(@base, 2, :second),
          window_ms: :timer.minutes(20)
        )

      assert Decimal.equal?(value, Decimal.new(0))
    end

    test "prices are capped at max_history_samples" do
      # Fixed `now` (see Derivative's identically-named test for why) so
      # only the hard cap, not the time-based trim, can be shrinking prices.
      final_prices =
        Enum.reduce(1..1000, [], fn i, prices ->
          {new_prices, _value} =
            Signals.donchian(prices, 100 + i * 1.0, @base, window_ms: :timer.minutes(20))

          new_prices
        end)

      assert length(final_prices) == 500
    end
  end

  describe "regime/4" do
    test "emits +1 (long) when direction exceeds the deadband and the gate is calm" do
      value = Signals.regime(Decimal.new(500), Decimal.new(0), Decimal.new(300), Decimal.new("1.5"))
      assert Decimal.equal?(value, Decimal.new(1))
    end

    test "emits -1 (short) when direction is below the negative deadband and the gate is calm" do
      value =
        Signals.regime(Decimal.new(-500), Decimal.new(0), Decimal.new(300), Decimal.new("1.5"))

      assert Decimal.equal?(value, Decimal.new(-1))
    end

    test "emits 0 (choppy) when direction is within the deadband" do
      value = Signals.regime(Decimal.new(50), Decimal.new(0), Decimal.new(300), Decimal.new("1.5"))
      assert Decimal.equal?(value, Decimal.new(0))
    end

    test "emits 0 (choppy) when the gate exceeds vix_gate_zscore, even with a strong direction" do
      value =
        Signals.regime(Decimal.new(800), Decimal.new(3), Decimal.new(300), Decimal.new("1.5"))

      assert Decimal.equal?(value, Decimal.new(0))
    end

    test "custom deadband/gate thresholds are honored" do
      value = Signals.regime(Decimal.new(60), Decimal.new(2), Decimal.new(50), Decimal.new("3.0"))
      assert Decimal.equal?(value, Decimal.new(1))
    end
  end

  describe "momentum/4" do
    test "no value until at least 2 prices are in the window" do
      {prices, value} = Signals.momentum([], 100.0, @base, window_ms: :timer.minutes(5))
      assert value == nil
      assert length(prices) == 1
    end

    test "matches a hand-computed newest-minus-oldest difference" do
      {prices, nil} = Signals.momentum([], 100.0, @base, window_ms: :timer.minutes(5))

      {_prices, value} =
        Signals.momentum(prices, 107.5, DateTime.add(@base, 1, :second),
          window_ms: :timer.minutes(5)
        )

      assert Decimal.equal?(value, Decimal.new("7.5"))
    end

    test "negative when price fell" do
      {prices, nil} = Signals.momentum([], 100.0, @base, window_ms: :timer.minutes(5))

      {_prices, value} =
        Signals.momentum(prices, 90.0, DateTime.add(@base, 1, :second),
          window_ms: :timer.minutes(5)
        )

      assert Decimal.equal?(value, Decimal.new("-10.0"))
    end

    test "prices outside the window are trimmed" do
      {prices, nil} = Signals.momentum([], 100.0, @base, window_ms: :timer.minutes(5))

      # 6 minutes later — outside the 5-minute window, so the 100.0 sample
      # should be trimmed, leaving only one sample (no value yet).
      {prices, value} =
        Signals.momentum(prices, 110.0, DateTime.add(@base, 6 * 60, :second),
          window_ms: :timer.minutes(5)
        )

      assert value == nil
      assert length(prices) == 1
    end

    test "prices are capped at max_history_samples" do
      # Fixed `now` (see Derivative's identically-named test for why) so
      # only the hard cap, not the time-based trim, can be shrinking prices.
      final_prices =
        Enum.reduce(1..1000, [], fn i, prices ->
          {new_prices, _value} =
            Signals.momentum(prices, 100 + i * 1.0, @base, window_ms: :timer.minutes(5))

          new_prices
        end)

      assert length(final_prices) == 500
    end
  end
end
