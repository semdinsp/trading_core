defmodule TradingCore.Signals.SignatureTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias TradingCore.Signal.{Compute, Spec}
  alias TradingCore.Signals.Signature

  defp levy(path, i \\ 0, j \\ 1), do: path |> Signature.signature() |> Signature.levy_area(i, j)

  # (x, y) unit square from the origin, closed.
  @ccw [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0], [0.0, 0.0]]

  describe "pure signature" do
    test "a straight line has zero Levy area" do
      assert levy([[0.0, 0.0], [1.0, 2.0], [2.0, 4.0], [3.0, 6.0]]) == 0.0
      assert levy([[5.0, 1.0], [5.0, 1.0]]) == 0.0
    end

    test "the unit square: +1 counter-clockwise, -1 clockwise" do
      assert_in_delta levy(@ccw), 1.0, 1.0e-12
      assert_in_delta levy(Enum.reverse(@ccw)), -1.0, 1.0e-12
    end

    test "Levy area is antisymmetric in its channels" do
      assert_in_delta levy(@ccw, 1, 0), -1.0, 1.0e-12
      assert levy(@ccw, 0, 0) == 0.0
    end

    test "level 1 is the total increment; S2[i][i] is half its square" do
      path = [[1.0, 10.0], [3.0, 7.0], [2.0, 9.0], [6.0, 4.0]]
      sig = Signature.signature(path)

      assert sig.level1 == [5.0, -6.0]
      assert_in_delta Enum.at(Enum.at(sig.level2, 0), 0), 12.5, 1.0e-12
      assert_in_delta Enum.at(Enum.at(sig.level2, 1), 1), 18.0, 1.0e-12
      # shuffle identity: S2[i][j] + S2[j][i] = S1[i] * S1[j]
      assert_in_delta Enum.at(Enum.at(sig.level2, 0), 1) + Enum.at(Enum.at(sig.level2, 1), 0),
                      -30.0,
                      1.0e-12

      assert length(Signature.level2_flat(sig)) == 4
    end

    test "when Y lags X by one bar the area has a consistent positive sign" do
      :rand.seed(:exsss, {3, 1, 4})

      for _ <- 1..50 do
        x = Enum.scan(1..40, 0.0, fn _, acc -> acc + :rand.normal() end)
        y = [hd(x) | Enum.drop(x, -1)]
        path = Enum.zip_with(x, y, &[&1, &2])

        assert levy(path) > 0, "X leads Y"
        assert levy(path, 1, 0) < 0
      end
    end

    test "normalize z-scores each channel and zeroes a flat one; the area keeps its sign" do
      path = [[10.0, 5.0], [12.0, 5.0], [14.0, 5.0]]
      [[a, f1], [b, f2], [c, f3]] = Signature.normalize(path)
      assert_in_delta a + b + c, 0.0, 1.0e-12
      assert {f1, f2, f3} == {0.0, 0.0, 0.0}

      scaled = Enum.map(@ccw, fn [x, y] -> [100 + 3 * x, -7 + 0.5 * y] end)
      assert levy(Signature.normalize(scaled)) > 0
    end
  end

  describe "Compute :signature" do
    defp spec(params) do
      %Spec{
        kind: :signature,
        symbol: "QQQ",
        reference_symbol: "SPY",
        params:
          Map.merge(
            %{
              "channels" => ["price", "reference"],
              "window" => 5,
              "normalize" => false,
              "pair" => [0, 1]
            },
            params
          )
      }
    end

    defp ticks(points) do
      t0 = ~U[2026-10-14 14:00:00Z]

      points
      |> Enum.with_index()
      |> Enum.map(fn {[x, y], i} -> %{at: DateTime.add(t0, i * 60), value: x, reference: y} end)
    end

    defp run(spec, ticks) do
      {:ok, st} = Compute.init(spec)

      {_st, out} =
        Enum.reduce(ticks, {st, []}, fn tick, {st, acc} ->
          {st, o} = Compute.step(spec, st, tick)
          {st, [o | acc]}
        end)

      Enum.reverse(out)
    end

    test "warms up for window - 1 bars, then the unit-square area (+1 / -1)" do
      out = run(spec(%{}), ticks(@ccw))
      assert Enum.take(out, 4) == List.duplicate(:warming_up, 4)
      assert List.last(out) == Decimal.new("1.00000000")

      assert List.last(run(spec(%{}), ticks(Enum.reverse(@ccw)))) == Decimal.new("-1.00000000")
    end

    test "the window rolls: only the last N bars count" do
      # a straight line before the square doesn't change the square's area
      line = for k <- 0..9, do: [-10.0 + k, -10.0 + k]
      assert List.last(run(spec(%{}), ticks(line ++ @ccw))) == Decimal.new("1.00000000")
    end

    test "level1 and level2 outputs" do
      assert List.last(run(spec(%{"output" => "level1", "index" => 0}), ticks(@ccw))) ==
               Decimal.new("0E-8")

      # S2[0][1] of the ccw square: x moves first, then y -> 1.0
      assert List.last(run(spec(%{"output" => "level2", "pair" => [0, 1]}), ticks(@ccw))) ==
               Decimal.new("1.00000000")
    end

    test "volume and time channels" do
      # time vs cumulative volume: a straight line when volume is constant
      vol_ticks =
        for i <- 0..5,
            do: %{at: DateTime.add(~U[2026-10-14 14:00:00Z], i * 60), value: 100.0, volume: 10}

      s = spec(%{"channels" => ["time", "volume"], "window" => 6})
      assert List.last(run(s, vol_ticks)) == Decimal.new("0E-8")
    end

    test "log channels skip non-positive prices instead of raising" do
      s = spec(%{"channels" => ["log_price", "reference"]})
      assert run(s, [%{at: ~U[2026-10-14 14:00:00Z], value: 0, reference: 1}]) == [:warming_up]
    end

    test "invalid params raise at init" do
      for bad <- [
            %{"channels" => ["price"]},
            %{"channels" => ["price", "bogus"]},
            %{"window" => 1},
            %{"normalize" => "yes"},
            %{"output" => "level3"},
            %{"pair" => [0, 0]},
            %{"pair" => [0, 5]},
            %{"output" => "level1"}
          ] do
        assert_raise ArgumentError, fn -> Compute.init(spec(bad)) end
      end
    end

    test "log_volume and log_cum_volume channels" do
      t0 = ~U[2026-10-14 14:00:00Z]
      vols = [0, 9, 99, 999]

      ticks =
        for {v, i} <- Enum.with_index(vols),
            do: %{at: DateTime.add(t0, i * 60), value: 100.0, volume: v}

      # log(1 + v) for v = 0, 9, 99, 999 is 0, ln 10, 2 ln 10, 3 ln 10 against time 0..3: a straight line
      s = spec(%{"channels" => ["time", "log_volume"], "window" => 4})
      assert List.last(run(s, ticks)) == Decimal.new("0E-8")

      # cumulative 0, 9, 108, 1107: total level-1 increment is log(1108)
      s =
        spec(%{
          "channels" => ["time", "log_cum_volume"],
          "window" => 4,
          "output" => "level1",
          "index" => 1
        })

      assert Decimal.equal?(
               List.last(run(s, ticks)),
               Decimal.from_float(:math.log(1108)) |> Decimal.round(8)
             )
    end

    @t0 ~U[2026-10-14 14:00:00Z]

    defp at(ms), do: DateTime.add(@t0, ms, :millisecond)

    # The same bars, but the symbol and the reference arrive as separate
    # ticks inside each minute, then one tick opens the next minute.
    defp split_ticks(points) do
      points
      |> Enum.with_index()
      |> Enum.flat_map(fn {[x, y], i} ->
        [%{at: at(i * 60_000 + 1_000), value: x}, %{at: at(i * 60_000 + 30_000), reference: y}]
      end)
    end

    test "bar_interval_ms: split symbol/reference ticks give the same area as combined bars" do
      clocked = spec(%{"bar_interval_ms" => 60_000})
      # a bar closes when the next minute's first tick arrives
      trailing = fn points -> %{at: at(length(points) * 60_000 + 1_000), value: 0.0} end

      assert List.last(run(clocked, split_ticks(@ccw) ++ [trailing.(@ccw)])) ==
               Decimal.new("1.00000000")

      # both channels moving together: a straight line, area 0
      diagonal = for k <- 0..5, do: [1.0 * k, 1.0 * k]

      assert List.last(run(clocked, split_ticks(diagonal) ++ [trailing.(diagonal)])) ==
               Decimal.new("0E-8")

      # without bar_interval_ms each one-sided tick is a bar: the line
      # becomes a staircase with the symbol always moving first, and the
      # area is a positive artefact
      per_tick = List.last(run(spec(%{"window" => 9}), split_ticks(diagonal)))
      assert Decimal.compare(per_tick, 0) == :gt
    end

    test "bar_interval_ms: a bar takes the last value in its interval and sums volume" do
      s =
        spec(%{
          "bar_interval_ms" => 60_000,
          "window" => 2,
          "channels" => ["price", "volume"],
          "output" => "level1",
          "index" => 1
        })

      out =
        run(s, [
          %{at: at(0), value: 1.0, volume: 5},
          %{at: at(10_000), value: 2.0, volume: 7},
          %{at: at(60_000), value: 3.0, volume: 100},
          %{at: at(120_000), value: 4.0, volume: 1}
        ])

      # bar 1: price 2, volume 12; bar 2: price 3, volume 100.
      # level1 of cumulative volume is 112 - 12 = 100.
      assert out == [:warming_up, :warming_up, :warming_up, Decimal.new("100.00000000")]

      # price channel: last-in-interval 2 -> 3, increment 1
      s1 = %{s | params: Map.put(s.params, "index", 0)}

      assert List.last(
               run(s1, [
                 %{at: at(0), value: 1.0},
                 %{at: at(10_000), value: 2.0},
                 %{at: at(60_000), value: 3.0},
                 %{at: at(120_000), value: 9.0}
               ])
             ) == Decimal.new("1.00000000")
    end

    test "bar_interval_ms: between closes it repeats the last value; empty intervals add no bar" do
      s = spec(%{"bar_interval_ms" => 60_000})
      line = for k <- 0..5, do: %{at: at(k * 60_000), value: 1.0 * k, reference: 2.0 * k}
      # a mid-minute tick and a tick 10 minutes later: no flat fill bars
      extra = [
        %{at: at(5 * 60_000 + 30_000), value: 5.0},
        %{at: at(15 * 60_000), value: 6.0, reference: 12.0}
      ]

      out = run(s, line ++ extra)

      assert Enum.take(out, 5) == List.duplicate(:warming_up, 5)
      assert Enum.at(out, 5) == Decimal.new("0E-8")
      assert Enum.at(out, 6) == Enum.at(out, 5)
      assert %Decimal{} = Enum.at(out, 7)
    end

    test "bar_interval_ms: a late tick counts toward the open bar" do
      s =
        spec(%{
          "bar_interval_ms" => 60_000,
          "window" => 2,
          "channels" => ["price", "volume"],
          "output" => "level1",
          "index" => 1
        })

      out =
        run(s, [
          %{at: at(60_000), value: 1.0, volume: 1},
          %{at: at(30_000), value: 1.0, volume: 4},
          %{at: at(120_000), value: 1.0, volume: 10},
          %{at: at(180_000), value: 1.0, volume: 0}
        ])

      assert List.last(out) == Decimal.new("10.00000000")
    end

    test "bar_interval_ms: invalid bar_interval_ms raises" do
      for bad <- [0, -1, 1.5, "60000"] do
        assert_raise ArgumentError, fn -> Compute.init(spec(%{"bar_interval_ms" => bad})) end
      end
    end

    property "replay/3 equals folding step/2" do
      check all(
              xs <- list_of(float(min: 50.0, max: 150.0), min_length: 2, max_length: 40),
              ys <- list_of(float(min: 50.0, max: 150.0), length: length(xs)),
              normalize <- boolean(),
              clocked <- boolean(),
              max_runs: 80
            ) do
        s =
          spec(%{
            "window" => 6,
            "normalize" => normalize,
            "channels" => ["log_price", "reference_log_price"],
            "bar_interval_ms" => if(clocked, do: 90_000)
          })

        ts = ticks(Enum.zip_with(xs, ys, &[&1, &2]))

        assert run(s, ts) == Compute.replay(s, ts, only: s)
      end
    end
  end
end
