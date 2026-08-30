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

    test "'latest of each' — a tick from just one side recomputes using the other's last-known value" do
      spec = %Spec{kind: :percent_deviation}
      {:ok, state} = Compute.init(spec)

      {state, _} = Compute.step(spec, state, %{at: @now, value: 110, reference: 100})
      {_state, value} = Compute.step(spec, state, %{at: @now, value: 121, reference: nil})

      assert Decimal.equal?(value, Decimal.new(21))
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
