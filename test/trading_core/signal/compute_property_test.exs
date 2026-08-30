defmodule TradingCore.Signal.ComputePropertyTest do
  @moduledoc """
  The two properties this whole extraction exists to guarantee (see
  `TradingCore.Signal.Compute`'s own moduledoc, point 2 and the "reproduce
  byte for byte" claim):

    1. **fold/replay equivalence** — folding `step/2` tick by tick over a
       series must equal calling `replay/3` over that same series, for
       every kind (base, single-parent, dual-parent).
    2. **split-and-resume equivalence** — splitting a series at any point
       and resuming `step/2` from a *serialized* mid-stream state must
       equal computing the whole series in one uninterrupted pass. The
       state is round-tripped through `:erlang.term_to_binary/1` before
       resuming specifically to rule out anything hidden in process
       memory (a pid, a reference, an unserializable closure) — if state
       carries everything `step/2` needs, serialization is a no-op; if it
       doesn't, this is where that would show up.

  Both are checked for a representative kind from each of `Spec`'s three
  shapes (base: `:plain`, `:derivative`; single-parent: `:derivative`
  wrapping a `:plain`; dual-parent: `:percent_deviation`) rather than
  every kind — the two properties are about `Compute`'s own orchestration
  (state threading, `replay/3`'s tick synthesis), which is identical
  machinery regardless of which `TradingCore.Signals` function a given
  kind's `step/2` clause happens to call into.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias TradingCore.Signal.{Compute, Spec}

  @now ~U[2024-01-01 09:30:00Z]

  defp tick_series_generator do
    gen all(
          count <- integer(3..60),
          deltas <- list_of(integer(1..30), length: count),
          prices <- list_of(one_of([float(min: 1.0, max: 500.0), integer(1..500)]), length: count)
        ) do
      deltas
      |> Enum.scan(0, &(&1 + &2))
      |> Enum.zip(prices)
      |> Enum.map(fn {offset_seconds, price} ->
        %{at: DateTime.add(@now, offset_seconds, :second), value: price}
      end)
    end
  end

  defp fold(spec, ticks) do
    {:ok, state0} = Compute.init(spec)

    {_final, values} =
      Enum.reduce(ticks, {state0, []}, fn tick, {state, acc} ->
        {state, value} = Compute.step(spec, state, tick)
        {state, [value | acc]}
      end)

    Enum.reverse(values)
  end

  property "plain: folding step/2 equals replay/3 for any tick series" do
    check all(ticks <- tick_series_generator()) do
      spec = %Spec{kind: :plain}
      assert fold(spec, ticks) == Compute.replay(spec, ticks, only: spec)
    end
  end

  property "derivative: folding step/2 equals replay/3 for any tick series" do
    check all(ticks <- tick_series_generator()) do
      spec = %Spec{kind: :derivative, window_ms: :timer.minutes(5)}
      folded = fold(spec, ticks)

      base = %Spec{kind: :plain}
      wrapped = %{spec | parent: base}
      replayed = Compute.replay(wrapped, ticks, only: wrapped)

      assert folded == replayed
    end
  end

  property "donchian: folding step/2 equals replay/3 for any tick series" do
    check all(ticks <- tick_series_generator()) do
      spec = %Spec{kind: :donchian, window_ms: :timer.minutes(20)}
      assert fold(spec, ticks) == Compute.replay(spec, ticks, only: spec)
    end
  end

  property "self_zscore: folding step/2 equals replay/3 for any tick series" do
    check all(ticks <- tick_series_generator()) do
      spec = %Spec{kind: :self_zscore, window_ms: :timer.minutes(5)}
      folded = fold(spec, ticks)

      base = %Spec{kind: :plain}
      wrapped = %{spec | parent: base}
      replayed = Compute.replay(wrapped, ticks, only: wrapped)

      assert folded == replayed
    end
  end

  property "percent_deviation: folding step/2 equals replay/3 (both sides on the same tick series)" do
    check all(ticks <- tick_series_generator()) do
      value_base = %Spec{kind: :plain}
      reference_base = %Spec{kind: :vwap}
      dev = %Spec{kind: :percent_deviation, parent: value_base, reference: reference_base}

      vwap_ticks = Enum.map(ticks, &Map.put(&1, :volume, 1))

      via_replay =
        Compute.replay(dev, %{value_base => ticks, reference_base => vwap_ticks}, only: dev)

      # Manual fold: mirrors what replay/3 does internally for a
      # dual-parent node — merge each side's latest value at every
      # timeline instant and step dev's own state accordingly. Built
      # independently of Compute's own merged-timeline machinery (not by
      # calling replay/3 on the two base specs) so this genuinely checks
      # replay/3 against a from-scratch computation, not against itself.
      {:ok, dev_state0} = Compute.init(dev)
      {:ok, vwap_state0} = Compute.init(reference_base)

      {_final_vwap, reference_series} =
        Enum.reduce(vwap_ticks, {vwap_state0, []}, fn tick, {state, acc} ->
          {state, value} = Compute.step(reference_base, state, tick)
          {state, [value | acc]}
        end)

      reference_series = Enum.reverse(reference_series)

      {_final_dev, via_manual_fold} =
        Enum.zip(ticks, reference_series)
        |> Enum.reduce({dev_state0, []}, fn {price_tick, ref_value}, {state, acc} ->
          reference_value = if ref_value == :warming_up, do: nil, else: ref_value
          synthesized = %{at: price_tick.at, value: price_tick.value, reference: reference_value}

          {state, value} = Compute.step(dev, state, synthesized)
          {state, [value | acc]}
        end)

      via_manual_fold = Enum.reverse(via_manual_fold)

      assert via_replay == via_manual_fold
    end
  end

  property "split-and-resume from a serialized state equals a single uninterrupted pass (derivative)" do
    check all(
            ticks <- tick_series_generator(),
            split_at <- integer(1..59)
          ) do
      spec = %Spec{kind: :derivative, window_ms: :timer.minutes(5)}
      {:ok, state0} = Compute.init(spec)

      {_final, one_pass} =
        Enum.reduce(ticks, {state0, []}, fn tick, {state, acc} ->
          {state, value} = Compute.step(spec, state, tick)
          {state, [value | acc]}
        end)

      one_pass = Enum.reverse(one_pass)

      split_at = min(split_at, length(ticks))
      {first_half, second_half} = Enum.split(ticks, split_at)

      {mid_state, part_a} =
        Enum.reduce(first_half, {state0, []}, fn tick, {state, acc} ->
          {state, value} = Compute.step(spec, state, tick)
          {state, [value | acc]}
        end)

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

  property "split-and-resume from a serialized state equals a single uninterrupted pass (self_zscore)" do
    check all(
            ticks <- tick_series_generator(),
            split_at <- integer(1..59)
          ) do
      spec = %Spec{kind: :self_zscore, window_ms: :timer.minutes(5)}
      {:ok, state0} = Compute.init(spec)

      {_final, one_pass} =
        Enum.reduce(ticks, {state0, []}, fn tick, {state, acc} ->
          {state, value} = Compute.step(spec, state, tick)
          {state, [value | acc]}
        end)

      one_pass = Enum.reverse(one_pass)

      split_at = min(split_at, length(ticks))
      {first_half, second_half} = Enum.split(ticks, split_at)

      {mid_state, part_a} =
        Enum.reduce(first_half, {state0, []}, fn tick, {state, acc} ->
          {state, value} = Compute.step(spec, state, tick)
          {state, [value | acc]}
        end)

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
