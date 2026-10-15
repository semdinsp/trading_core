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

    property "replay/3 equals folding step/2" do
      check all(
              xs <- list_of(float(min: 50.0, max: 150.0), min_length: 2, max_length: 40),
              ys <- list_of(float(min: 50.0, max: 150.0), length: length(xs)),
              normalize <- boolean(),
              max_runs: 80
            ) do
        s =
          spec(%{
            "window" => 6,
            "normalize" => normalize,
            "channels" => ["log_price", "reference_log_price"]
          })

        ts = ticks(Enum.zip_with(xs, ys, &[&1, &2]))

        assert run(s, ts) == Compute.replay(s, ts, only: s)
      end
    end
  end
end
