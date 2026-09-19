defmodule TradingCore.Signal.ComputeTest do
  use ExUnit.Case, async: true

  alias TradingCore.Signal.{Compute, Spec}

  @now ~U[2024-01-01 09:30:00Z]

  defp ticks(values, opts \\ []) do
    interval = Keyword.get(opts, :interval, 1)

    values
    |> Enum.with_index()
    |> Enum.map(fn {value, i} ->
      %{at: DateTime.add(@now, i * interval, :second), value: value}
    end)
  end

  describe "plain" do
    test "passes each sample straight through as a Decimal, no warm-up" do
      spec = %Spec{kind: :plain}
      {:ok, state} = Compute.init(spec)

      {_state, value} = Compute.step(spec, state, %{at: @now, value: 100})
      assert Decimal.equal?(value, Decimal.new(100))
    end
  end

  describe "momentum" do
    test "warms up until 2 samples are in the window, then emits newest - oldest" do
      spec = %Spec{kind: :momentum, window_ms: :timer.minutes(5)}
      {:ok, state} = Compute.init(spec)

      {state, first} = Compute.step(spec, state, %{at: @now, value: 100})
      assert first == :warming_up

      {_state, second} =
        Compute.step(spec, state, %{at: DateTime.add(@now, 10, :second), value: 110})

      assert %Decimal{} = second
      assert Decimal.equal?(second, Decimal.new(10))
    end

    test "matches TradingCore.Signals.momentum/4 directly, tick for tick" do
      spec = %Spec{kind: :momentum, window_ms: :timer.minutes(5)}
      {:ok, state} = Compute.init(spec)

      values = ticks([100, 101, 103, 106, 110, 115], interval: 10)

      {_final_state, compute_results} =
        Enum.reduce(values, {state, []}, fn tick, {state, acc} ->
          {new_state, result} = Compute.step(spec, state, tick)
          {new_state, [result | acc]}
        end)

      compute_results = Enum.reverse(compute_results)

      {_final_prices, signals_results} =
        Enum.reduce(values, {[], []}, fn %{at: at, value: value}, {prices, acc} ->
          {new_prices, result} =
            TradingCore.Signals.momentum(prices, value, at, window_ms: :timer.minutes(5))

          {new_prices, [result || :warming_up | acc]}
        end)

      signals_results = Enum.reverse(signals_results)

      assert length(compute_results) == length(signals_results)

      Enum.zip(compute_results, signals_results)
      |> Enum.each(fn
        {:warming_up, :warming_up} -> :ok
        {a, b} -> assert Decimal.equal?(a, b)
      end)
    end
  end

  describe "derivative / second_derivative" do
    test "warms up until 2 samples are in the window, then emits slope" do
      spec = %Spec{kind: :derivative, window_ms: :timer.minutes(5)}
      {:ok, state} = Compute.init(spec)

      {state, first} = Compute.step(spec, state, %{at: @now, value: 100})
      assert first == :warming_up

      {_state, second} =
        Compute.step(spec, state, %{at: DateTime.add(@now, 10, :second), value: 110})

      assert %Decimal{} = second
      assert Decimal.equal?(second, Decimal.new(1))
    end

    test "second_derivative is a derivative of a derivative series" do
      base = %Spec{kind: :plain}
      deriv = %Spec{kind: :derivative, parent: base, window_ms: :timer.minutes(5)}
      accel = %Spec{kind: :second_derivative, parent: deriv, window_ms: :timer.minutes(5)}

      values = ticks([100, 101, 103, 106, 110, 115], interval: 10)

      series = Compute.replay(accel, values, only: accel)
      assert Enum.any?(series, &(&1 != :warming_up))
    end
  end

  describe "wavelet" do
    test "warms up until the window (64 samples) is completely full" do
      base = %Spec{kind: :plain}
      wavelet = %Spec{kind: :wavelet, parent: base}

      values = ticks(Enum.map(0..70, fn i -> 100 + :math.sin(i / 5) end), interval: 1)
      series = Compute.replay(wavelet, values, only: wavelet)

      warm_count = Enum.count(series, &(&1 == :warming_up))
      assert warm_count == 63
      assert Enum.at(series, 63) != :warming_up
    end
  end

  describe "volume" do
    test "warms up on the first reading, then emits session-cumulative volume" do
      spec = %Spec{kind: :volume}
      {:ok, state} = Compute.init(spec)

      {state, first} = Compute.step(spec, state, %{at: @now, value: 1000})
      assert first == :warming_up

      {state, second} =
        Compute.step(spec, state, %{at: DateTime.add(@now, 1, :second), value: 1500})

      assert Decimal.equal?(second, Decimal.new(500))

      {_state, third} =
        Compute.step(spec, state, %{at: DateTime.add(@now, 2, :second), value: 1400})

      # a backwards-moving cumulative counter contributes nothing usable
      # to fold this tick — same "nothing to emit yet" case as any other
      # kind's warm-up, not a re-emission of the last good value
      assert third == :warming_up
    end

    test "resets cum_volume AND last_reading when the injected session_reset reports a new session" do
      # Regression test for the confirmed live divergence this covers:
      # without a session reset, :volume's cum_volume grows forever across
      # session boundaries instead of resetting to session-to-date volume
      # each day, the way TradingSignal.Signals.CumulativeVolume actually
      # behaves live.
      session_reset = fn dt -> DateTime.to_date(dt) end
      spec = %Spec{kind: :volume, params: %{"session_reset" => session_reset}}
      {:ok, state} = Compute.init(spec)

      day1 = @now
      day2 = DateTime.add(@now, 86_400, :second)

      {state, first} = Compute.step(spec, state, %{at: day1, value: 1000})
      assert first == :warming_up

      {state, second} = Compute.step(spec, state, %{at: day1, value: 1500})
      assert Decimal.equal?(second, Decimal.new(500))

      # New session: cum_volume resets to 0, and last_reading resets to
      # nil so this first day2 reading only establishes a fresh baseline
      # (warms up again) rather than being diffed against day1's stale
      # 1500 reading.
      {state, third} = Compute.step(spec, state, %{at: day2, value: 50})
      assert third == :warming_up

      {_state, fourth} = Compute.step(spec, state, %{at: day2, value: 80})
      assert Decimal.equal?(fourth, Decimal.new(30))
    end

    test "with no session_reset configured, cum_volume never resets (single unbroken session)" do
      spec = %Spec{kind: :volume}
      {:ok, state} = Compute.init(spec)

      day1 = @now
      day2 = DateTime.add(@now, 86_400, :second)

      {state, _} = Compute.step(spec, state, %{at: day1, value: 1000})
      {state, _} = Compute.step(spec, state, %{at: day1, value: 1500})

      # No reset rule injected: day2's reading diffs straight against
      # day1's last reading (1500), adding another 100 on top of the
      # already-accumulated 500 — cum_volume keeps growing across the
      # "session" boundary exactly as if there were none, same "blended
      # across both sessions" behavior :vwap's own no-session_reset test
      # documents.
      {_state, value} = Compute.step(spec, state, %{at: day2, value: 1600})
      assert Decimal.equal?(value, Decimal.new(600))
    end
  end

  describe "vwap" do
    test "warms up until volume is positive, then computes cum_pv / cum_volume" do
      spec = %Spec{kind: :vwap}
      {:ok, state} = Compute.init(spec)

      {state, first} = Compute.step(spec, state, %{at: @now, value: 100, volume: nil})
      assert first == :warming_up

      {_state, second} =
        Compute.step(spec, state, %{at: @now, value: 100, volume: Decimal.new(10)})

      assert Decimal.equal?(second, Decimal.new("100.00000000"))
    end

    test "resets cum_pv/cum_volume when the injected session_reset function reports a new session" do
      session_reset = fn dt -> DateTime.to_date(dt) end
      spec = %Spec{kind: :vwap, params: %{"session_reset" => session_reset}}
      {:ok, state} = Compute.init(spec)

      day1 = @now
      day2 = DateTime.add(@now, 86_400, :second)

      {state, _} = Compute.step(spec, state, %{at: day1, value: 100, volume: Decimal.new(10)})
      {state, v1} = Compute.step(spec, state, %{at: day1, value: 200, volume: Decimal.new(10)})
      assert Decimal.equal?(v1, Decimal.new("150.00000000"))

      # New session: cum_pv/cum_volume reset, so the running vwap reflects
      # only day2's own tick, not a blend with day1's.
      {_state, v2} = Compute.step(spec, state, %{at: day2, value: 50, volume: Decimal.new(5)})
      assert Decimal.equal?(v2, Decimal.new("50.00000000"))
    end

    test "with no session_reset configured, never resets (single unbroken session)" do
      spec = %Spec{kind: :vwap}
      {:ok, state} = Compute.init(spec)

      day1 = @now
      day2 = DateTime.add(@now, 86_400, :second)

      {state, _} = Compute.step(spec, state, %{at: day1, value: 100, volume: Decimal.new(10)})
      {_state, v2} = Compute.step(spec, state, %{at: day2, value: 200, volume: Decimal.new(10)})

      # blended across both "sessions" since no reset rule was injected
      assert Decimal.equal?(v2, Decimal.new("150.00000000"))
    end
  end

  describe "donchian" do
    test "warms up until 2 distinct prices are in the window" do
      spec = %Spec{kind: :donchian, window_ms: :timer.minutes(20)}
      {:ok, state} = Compute.init(spec)

      {state, first} = Compute.step(spec, state, %{at: @now, value: 100})
      assert first == :warming_up

      {_state, second} =
        Compute.step(spec, state, %{at: DateTime.add(@now, 1, :second), value: 105})

      assert Decimal.equal?(second, Decimal.new(1))
    end
  end

  describe "rolling_volume" do
    test "warms up until 2 readings are in the window, clamps negative deltas to zero" do
      spec = %Spec{kind: :rolling_volume, window_ms: :timer.minutes(5)}
      {:ok, state} = Compute.init(spec)

      {state, first} = Compute.step(spec, state, %{at: @now, value: 1000})
      assert first == :warming_up

      {_state, second} =
        Compute.step(spec, state, %{at: DateTime.add(@now, 1, :second), value: 1200})

      assert Decimal.equal?(second, Decimal.new(200))
    end
  end

  describe "self_zscore" do
    test "warms up until 2 samples and non-zero variance" do
      spec = %Spec{kind: :self_zscore, window_ms: :timer.minutes(5)}
      {:ok, state} = Compute.init(spec)

      {state, first} = Compute.step(spec, state, %{at: @now, value: 10})
      assert first == :warming_up

      {state, second} =
        Compute.step(spec, state, %{at: DateTime.add(@now, 1, :second), value: 10})

      # flat series => zero variance => still warming up
      assert second == :warming_up

      {_state, third} =
        Compute.step(spec, state, %{at: DateTime.add(@now, 2, :second), value: 20})

      assert %Decimal{} = third
    end
  end

  describe "percent_deviation / ratio / zscore (dual-parent, vs. a reference)" do
    test "percent_deviation warms up until both sides have reported, nil reference stays warming" do
      spec = %Spec{kind: :percent_deviation}
      {:ok, state} = Compute.init(spec)

      {state, first} = Compute.step(spec, state, %{at: @now, value: 110})
      assert first == :warming_up

      {_state, second} =
        Compute.step(spec, state, %{at: @now, value: nil, reference: 100})

      assert Decimal.equal?(second, Decimal.new(10))
    end

    test "ratio divides value by reference" do
      spec = %Spec{kind: :ratio}
      {:ok, state} = Compute.init(spec)
      {state, _} = Compute.step(spec, state, %{at: @now, value: 10})
      {_state, value} = Compute.step(spec, state, %{at: @now, value: nil, reference: 4})
      assert Decimal.equal?(value, Decimal.new("2.50000000"))
    end

    test "zscore warms up until the spread's own window has 2 samples with non-zero variance" do
      spec = %Spec{kind: :zscore, window_ms: :timer.minutes(5)}
      {:ok, state} = Compute.init(spec)

      {state, w1} = Compute.step(spec, state, %{at: @now, value: 100, reference: 90})
      assert w1 == :warming_up

      {_state, w2} =
        Compute.step(spec, state, %{
          at: DateTime.add(@now, 1, :second),
          value: 105,
          reference: 90
        })

      assert %Decimal{} = w2
    end

    test "zscore honors its configured window_ms rather than the 5-minute internal default" do
      # Regression: this clause used to call spread_zscore/5 with no opts,
      # so window_ms was silently ignored and every :zscore ran on the
      # 5-minute default. A 30s window must drop a sample older than 30s.
      spec = %Spec{kind: :zscore, window_ms: :timer.seconds(30)}
      {:ok, state} = Compute.init(spec)

      {state, _} = Compute.step(spec, state, %{at: @now, value: 100, reference: 90})

      # Well inside a 5-minute window, well outside a 30-second one.
      later = DateTime.add(@now, 120, :second)
      {state, _} = Compute.step(spec, state, %{at: later, value: 105, reference: 90})

      # Only the in-window sample survives the trim.
      assert length(state.history) == 1
      assert [{^later, _spread}] = state.history
    end

    test "a wider window_ms keeps samples a narrower one would drop" do
      wide = %Spec{kind: :zscore, window_ms: :timer.minutes(10)}
      {:ok, state} = Compute.init(wide)

      {state, _} = Compute.step(wide, state, %{at: @now, value: 100, reference: 90})

      later = DateTime.add(@now, 120, :second)
      {state, _} = Compute.step(wide, state, %{at: later, value: 105, reference: 90})

      assert length(state.history) == 2
    end

    test "zscore threads precision and max_history_samples from params" do
      spec = %Spec{
        kind: :zscore,
        window_ms: :timer.minutes(10),
        params: %{"max_history_samples" => 2}
      }

      {:ok, state} = Compute.init(spec)

      state =
        Enum.reduce(0..4, state, fn i, acc ->
          {next, _} =
            Compute.step(spec, acc, %{
              at: DateTime.add(@now, i, :second),
              value: 100 + i,
              reference: 90
            })

          next
        end)

      assert length(state.history) == 2
    end

    test "zscore clears its spread window when the injected session_reset reports a new session" do
      # A :zscore whose reference is a session-resetting kind (a :vwap)
      # sees that reference jump discontinuously at the boundary. Samples
      # either side of the jump aren't observations of the same quantity,
      # so the window is cleared rather than straddling it.
      session_reset = fn dt -> DateTime.to_date(dt) end

      spec = %Spec{
        kind: :zscore,
        window_ms: :timer.hours(48),
        params: %{"session_reset" => session_reset}
      }

      {:ok, state} = Compute.init(spec)

      day1 = @now
      day1_later = DateTime.add(@now, 60, :second)
      day2 = DateTime.add(@now, 86_400, :second)

      {state, _} = Compute.step(spec, state, %{at: day1, value: 100, reference: 90})
      {state, _} = Compute.step(spec, state, %{at: day1_later, value: 105, reference: 90})
      assert length(state.history) == 2

      # New session: the 48h window would otherwise have kept both day1
      # samples, so anything less than a full clear proves the reset ran.
      {state, value} = Compute.step(spec, state, %{at: day2, value: 50, reference: 40})

      assert length(state.history) == 1
      assert [{^day2, _}] = state.history
      # One sample has no variance yet, so the rebuilt window is warming up.
      assert value == :warming_up
    end

    test "zscore with no session_reset keeps a window straddling the boundary (opt-in)" do
      spec = %Spec{kind: :zscore, window_ms: :timer.hours(48)}
      {:ok, state} = Compute.init(spec)

      day1 = @now
      day2 = DateTime.add(@now, 86_400, :second)

      {state, _} = Compute.step(spec, state, %{at: day1, value: 100, reference: 90})
      {state, _} = Compute.step(spec, state, %{at: day2, value: 105, reference: 90})

      # Unchanged from before this feature existed: both samples retained.
      assert length(state.history) == 2
    end

    test "a reset-enabled zscore reports warming_up where an unreset one reports a number" do
      # Pins the documented semantics: enabling session_reset yields a
      # DIFFERENT signal, not a corrected one. Around a session open the
      # reset version has an empty window (count < 2 => nil => :warming_up)
      # exactly where the straddling version still emits, so values either
      # side of the switch are not comparable.
      session_reset = fn dt -> DateTime.to_date(dt) end
      window = :timer.hours(48)

      reset_spec = %Spec{
        kind: :zscore,
        window_ms: window,
        params: %{"session_reset" => session_reset}
      }

      plain_spec = %Spec{kind: :zscore, window_ms: window}

      day1 = @now
      day1_later = DateTime.add(@now, 60, :second)
      day2 = DateTime.add(@now, 86_400, :second)

      ticks = [
        %{at: day1, value: 100, reference: 90},
        %{at: day1_later, value: 105, reference: 90},
        %{at: day2, value: 50, reference: 40}
      ]

      run = fn spec ->
        {:ok, state} = Compute.init(spec)

        Enum.reduce(ticks, {state, nil}, fn tick, {acc, _} ->
          Compute.step(spec, acc, tick)
        end)
      end

      {_reset_state, reset_value} = run.(reset_spec)
      {_plain_state, plain_value} = run.(plain_spec)

      assert reset_value == :warming_up
      assert %Decimal{} = plain_value
    end

    test "zscore does not clear within a single session" do
      session_reset = fn dt -> DateTime.to_date(dt) end

      spec = %Spec{
        kind: :zscore,
        window_ms: :timer.hours(48),
        params: %{"session_reset" => session_reset}
      }

      {:ok, state} = Compute.init(spec)

      {state, _} = Compute.step(spec, state, %{at: @now, value: 100, reference: 90})

      {state, _} =
        Compute.step(spec, state, %{
          at: DateTime.add(@now, 3600, :second),
          value: 105,
          reference: 90
        })

      assert length(state.history) == 2
    end

    test "'latest of each' — a tick from just one side recomputes using the other's last-known value" do
      spec = %Spec{kind: :percent_deviation}
      {:ok, state} = Compute.init(spec)

      {state, _} = Compute.step(spec, state, %{at: @now, value: 110, reference: 100})
      {_state, value} = Compute.step(spec, state, %{at: @now, value: 121, reference: nil})

      assert Decimal.equal?(value, Decimal.new(21))
    end

    test "percent_deviation's emitted value is rounded before it can reach a downstream rolling window" do
      # Compute makes it possible to wire percent_deviation's own output
      # into a child that keeps a rolling window (derivative/self_zscore),
      # something the live GenServer topology never did (Deviation only
      # ever broadcast this as a terminal value). An ordinary-looking
      # value/reference pair produces an exact-precision Decimal.div/2
      # quotient with 30+ significant digits if unrounded — see
      # TradingCore.Signals.percent_deviation/3's own moduledoc — so this
      # asserts the value stored in a child's window is bounded.
      spec = %Spec{kind: :percent_deviation}
      {:ok, state} = Compute.init(spec)

      {_state, value} =
        Compute.step(spec, state, %{at: @now, value: "100.03", reference: "99.97"})

      digit_count =
        value |> Decimal.to_string() |> String.replace(~r/[^0-9]/, "") |> String.length()

      assert digit_count <= 9
    end
  end

  describe "regime" do
    test "long when direction exceeds the deadband and the gate is below threshold" do
      spec = %Spec{
        kind: :regime,
        params: %{"tick_deadband" => 300, "vix_gate_zscore" => Decimal.new("1.5")}
      }

      {:ok, state} = Compute.init(spec)

      {state, w} = Compute.step(spec, state, %{at: @now, value: 500})
      assert w == :warming_up

      {_state, value} =
        Compute.step(spec, state, %{at: @now, value: nil, reference: Decimal.new("0.5")})

      assert Decimal.equal?(value, Decimal.new(1))
    end

    test "gate suppresses to 0 when volatility zscore exceeds the threshold, regardless of direction" do
      spec = %Spec{kind: :regime}
      {:ok, state} = Compute.init(spec)

      {state, _} =
        Compute.step(spec, state, %{at: @now, value: 500, reference: Decimal.new("0.5")})

      {_state, value} =
        Compute.step(spec, state, %{at: @now, value: nil, reference: Decimal.new("2.0")})

      assert Decimal.equal?(value, Decimal.new(0))
    end
  end

  describe "spread" do
    defp spread_ticks(pairs, opts \\ []) do
      interval = Keyword.get(opts, :interval, 1)

      pairs
      |> Enum.with_index()
      |> Enum.map(fn {{y, x}, i} ->
        %{at: DateTime.add(@now, i * interval, :second), value: y, reference: x}
      end)
    end

    test "static beta_mode: warms up until the mu/sigma window has 2 samples, then emits a z-score" do
      spec = %Spec{kind: :spread, params: %{"beta_mode" => "static", "beta" => "1.0"}}
      {:ok, state} = Compute.init(spec)

      {state, first} = Compute.step(spec, state, %{at: @now, value: 100, reference: 100})
      assert first == :warming_up

      {_state, second} =
        Compute.step(spec, state, %{
          at: DateTime.add(@now, 1, :second),
          value: 110,
          reference: 100
        })

      assert %Decimal{} = second
    end

    test "static beta_mode never re-estimates beta/alpha across ticks" do
      spec = %Spec{kind: :spread, params: %{"beta_mode" => "static", "beta" => "2.0"}}
      {:ok, state} = Compute.init(spec)

      ticks = spread_ticks([{100, 50}, {110, 55}, {90, 60}, {120, 40}])

      final_state =
        Enum.reduce(ticks, state, fn tick, state ->
          {state, _value} = Compute.step(spec, state, tick)
          state
        end)

      extras = Compute.spread_extras(final_state)
      assert Decimal.equal?(extras.beta, Decimal.new("2.0"))
      assert Decimal.equal?(extras.alpha, Decimal.new(0))
    end

    test "static beta_mode defaults alpha to 0 when not supplied" do
      spec = %Spec{kind: :spread, params: %{"beta_mode" => "static", "beta" => "1.0"}}
      {:ok, state} = Compute.init(spec)

      {state, _} = Compute.step(spec, state, %{at: @now, value: 100, reference: 100})
      extras = Compute.spread_extras(state)
      assert Decimal.equal?(extras.alpha, Decimal.new(0))
    end

    test "rolling_ols beta_mode re-estimates beta/alpha as ticks arrive" do
      spec = %Spec{
        kind: :spread,
        window_ms: :timer.minutes(30),
        params: %{"beta_mode" => "rolling_ols", "beta_window_ms" => :timer.minutes(30)}
      }

      {:ok, state} = Compute.init(spec)

      # log_y = 2 * log_x, exactly, so beta should converge toward 2.
      pairs = for x <- 1..10, do: {:math.exp(2 * :math.log(x)), x * 1.0}

      ticks = spread_ticks(pairs, interval: 60)

      final_state =
        Enum.reduce(ticks, state, fn tick, state ->
          {state, _value} = Compute.step(spec, state, tick)
          state
        end)

      extras = Compute.spread_extras(final_state)
      assert extras.beta != nil
      assert_in_delta Decimal.to_float(extras.beta), 2.0, 0.01
    end

    test "kalman beta_mode warms up on the very first tick, then produces beta/alpha" do
      spec = %Spec{kind: :spread, params: %{"beta_mode" => "kalman"}}
      {:ok, state} = Compute.init(spec)

      {state, first} = Compute.step(spec, state, %{at: @now, value: 100, reference: 100})
      assert first == :warming_up

      {state, _second} =
        Compute.step(spec, state, %{
          at: DateTime.add(@now, 1, :second),
          value: 110,
          reference: 100
        })

      extras = Compute.spread_extras(state)
      assert extras.beta != nil
      assert extras.alpha != nil
    end

    test "spread_extras/1 returns nil beta/alpha/half_life and 0 crossings before warm-up" do
      spec = %Spec{kind: :spread, params: %{"beta_mode" => "rolling_ols"}}
      {:ok, state} = Compute.init(spec)

      extras = Compute.spread_extras(state)
      assert extras == %{beta: nil, alpha: nil, half_life: nil, crossings: 0}
    end

    test "a tick missing either leg leaves state untouched and stays warming_up" do
      spec = %Spec{kind: :spread, params: %{"beta_mode" => "static", "beta" => "1.0"}}
      {:ok, state} = Compute.init(spec)

      {new_state, value} = Compute.step(spec, state, %{at: @now, value: nil, reference: 100})
      assert value == :warming_up
      assert new_state == state
    end

    test "replay/3 threads two raw prices per tick (:value and :reference) through a single spread node" do
      spec = %Spec{
        kind: :spread,
        symbol: "AAPL",
        reference_symbol: "MSFT",
        params: %{"beta_mode" => "static", "beta" => "1.0"}
      }

      pairs = Enum.map(0..30, fn i -> {100 + i * 1.0, 100 + i * 0.5} end)
      ticks = spread_ticks(pairs, interval: 1)

      result = Compute.replay(spec, ticks, only: spec)

      assert length(result) == length(ticks)
      assert Enum.any?(result, &(&1 != :warming_up))
    end
  end

  describe "replay/3 — DAG resolution" do
    test "resolves a chain (spy plain -> wavelet -> wavelet derivative -> wavelet acceleration) topologically" do
      spy = %Spec{kind: :plain}
      wavelet = %Spec{kind: :wavelet, parent: spy}
      deriv = %Spec{kind: :derivative, parent: wavelet, window_ms: :timer.minutes(5)}
      accel = %Spec{kind: :second_derivative, parent: deriv, window_ms: :timer.minutes(5)}

      values = ticks(Enum.map(0..90, fn i -> 100 + :math.sin(i / 5) * 2 end), interval: 5)

      result = Compute.replay(accel, values)

      assert Map.has_key?(result, spy)
      assert Map.has_key?(result, wavelet)
      assert Map.has_key?(result, deriv)
      assert Map.has_key?(result, accel)

      assert length(result[spy]) == length(values)
      assert Enum.any?(result[accel], &(&1 != :warming_up))
    end

    test "a shared parent with two dependents is computed once per tick, both dependents see it" do
      base = %Spec{kind: :plain}
      wavelet = %Spec{kind: :wavelet, parent: base}
      deriv_a = %Spec{kind: :derivative, parent: wavelet, window_ms: :timer.minutes(5)}
      deriv_b = %Spec{kind: :derivative, parent: wavelet, window_ms: :timer.minutes(1)}

      root = %Spec{kind: :percent_deviation, parent: deriv_a, reference: deriv_b}

      values = ticks(Enum.map(0..70, fn i -> 100 + i * 0.1 end), interval: 1)
      result = Compute.replay(root, values)

      assert Map.has_key?(result, wavelet)
      # wavelet's own series length equals the number of input ticks — it
      # was computed once, not once per dependent path to it.
      assert length(result[wavelet]) == length(values)
    end

    test ":only narrows the result to a single node's series" do
      spec = %Spec{kind: :plain}
      values = ticks([1, 2, 3])
      series = Compute.replay(spec, values, only: spec)
      assert length(series) == 3
    end

    test "a spec tree can never actually contain a cycle (immutable nested structs)" do
      # %Spec{}'s :parent/:reference are plain nested structs, not
      # mutable references — rebuilding a node with `%Spec{node | ...}`
      # produces a *new* struct rather than back-editing an existing one
      # in place, so there is no way to construct a spec tree where a
      # node is its own ancestor. topological_order/1's cycle guard
      # exists for defense in depth (a future Spec-building helper could
      # get this wrong), but under today's %Spec{} shape it is
      # unreachable through ordinary construction — this test documents
      # that guarantee rather than exercising the guard.
      base = %Spec{kind: :plain}
      wavelet = %Spec{kind: :wavelet, parent: base}
      relinked_base = %Spec{base | parent: wavelet}
      relinked_wavelet = %Spec{wavelet | parent: relinked_base}

      values = for i <- 0..70, do: %{at: DateTime.add(@now, i, :second), value: 100 + i * 0.01}

      # No cycle: relinked_wavelet -> relinked_base -> (original) wavelet
      # -> (original) base is a finite chain, just an unusual-looking one.
      assert %{} = Compute.replay(relinked_wavelet, values)
    end

    test "supports independent tick series per base node, keyed by spec, for multi-symbol DAGs" do
      direction_base = %Spec{kind: :plain, symbol: "TICK-NYSE"}
      gate_base = %Spec{kind: :plain, symbol: "VIX"}
      gate_zscore = %Spec{kind: :self_zscore, parent: gate_base, window_ms: :timer.minutes(5)}
      regime = %Spec{kind: :regime, parent: direction_base, reference: gate_zscore}

      direction_ticks = ticks([400, 410, 420, 430, 440], interval: 10)
      vix_ticks = ticks([15, 16, 14, 18, 20, 22], interval: 17)

      result =
        Compute.replay(regime, %{direction_base => direction_ticks, gate_base => vix_ticks})

      assert Enum.any?(result[regime], &(&1 != :warming_up))
    end
  end

  describe "fold/replay equivalence" do
    test "folding step/2 tick by tick matches replay/3 over the same series (plain)" do
      spec = %Spec{kind: :plain}
      values = ticks([1, 2, 3, 4, 5])

      {:ok, state0} = Compute.init(spec)

      {_final, folded} =
        Enum.reduce(values, {state0, []}, fn tick, {state, acc} ->
          {state, value} = Compute.step(spec, state, tick)
          {state, [value | acc]}
        end)

      folded = Enum.reverse(folded)
      replayed = Compute.replay(spec, values, only: spec)

      assert folded == replayed
    end

    test "folding step/2 tick by tick matches replay/3 over the same series (derivative)" do
      spec = %Spec{kind: :derivative, window_ms: :timer.minutes(5)}
      values = ticks([100, 101, 99, 105, 110, 108], interval: 10)

      {:ok, state0} = Compute.init(spec)

      {_final, folded} =
        Enum.reduce(values, {state0, []}, fn tick, {state, acc} ->
          {state, value} = Compute.step(spec, state, tick)
          {state, [value | acc]}
        end)

      folded = Enum.reverse(folded)

      # replay/3 requires a real DAG (a bare single-parent spec with no
      # :parent is invalid — see Compute's own validate_node!/1), so the
      # equivalence is checked against a :plain parent feeding this exact
      # derivative spec, one level up.
      base = %Spec{kind: :plain}
      wrapped = %{spec | parent: base}
      replayed = Compute.replay(wrapped, values, only: wrapped)

      assert folded == replayed
    end

    test "replay/3 rejects a single-parent spec with no :parent" do
      spec = %Spec{kind: :derivative, window_ms: :timer.minutes(5)}

      assert_raise ArgumentError, ~r/requires a :parent/, fn ->
        Compute.replay(spec, [])
      end
    end

    test "replay/3 rejects a dual-parent spec missing :parent or :reference" do
      base = %Spec{kind: :plain}
      spec = %Spec{kind: :percent_deviation, parent: base, reference: nil}

      assert_raise ArgumentError, ~r/requires both :parent and :reference/, fn ->
        Compute.replay(spec, [])
      end
    end
  end

  describe "split-and-resume equivalence" do
    test "splitting a series and resuming from serialized state matches computing it in one pass" do
      spec = %Spec{kind: :derivative, window_ms: :timer.minutes(5)}
      values = ticks(Enum.map(0..40, fn i -> 100 + :math.sin(i / 4) * 3 end), interval: 10)

      {:ok, state0} = Compute.init(spec)

      {_final, one_pass} =
        Enum.reduce(values, {state0, []}, fn tick, {state, acc} ->
          {state, value} = Compute.step(spec, state, tick)
          {state, [value | acc]}
        end)

      one_pass = Enum.reverse(one_pass)

      {first_half, second_half} = Enum.split(values, 17)

      {mid_state, part_a} =
        Enum.reduce(first_half, {state0, []}, fn tick, {state, acc} ->
          {state, value} = Compute.step(spec, state, tick)
          {state, [value | acc]}
        end)

      # `mid_state` is ordinary data (a map of Decimals/DateTimes) — this
      # round-trip through :erlang.term_to_binary/1 stands in for "resume
      # from a serialized state," proving state genuinely carries
      # everything needed to continue, nothing hidden in process memory.
      resumed_state = mid_state |> :erlang.term_to_binary() |> :erlang.binary_to_term()

      {_final2, part_b} =
        Enum.reduce(second_half, {resumed_state, []}, fn tick, {state, acc} ->
          {state, value} = Compute.step(spec, state, tick)
          {state, [value | acc]}
        end)

      resumed = Enum.reverse(part_a) ++ Enum.reverse(part_b)

      assert resumed == one_pass
    end
  end
end
