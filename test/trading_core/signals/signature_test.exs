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

    defp qspec(params) do
      %Spec{
        kind: :signature,
        symbol: "QQQ",
        params:
          Map.merge(
            %{
              "channels" => ["cum_ofi", "mid"],
              "window" => 8,
              "bar_interval_ms" => 1000,
              "normalize" => true,
              "pair" => [0, 1]
            },
            params
          )
      }
    end

    defp sec(s, ms \\ 0), do: DateTime.add(@t0, s * 1000 + ms, :millisecond)

    defp quote_tick(s, bid, ask, bid_size, ask_size),
      do: %{at: sec(s), bid: bid, ask: ask, bid_size: bid_size, ask_size: ask_size}

    # Cleanly separated events (ask size is always 0, and a price move
    # resets the bid size to 0, so a move contributes no OFI):
    #   :flow  bid size 0 -> 100 at the same price: OFI +100, mid unchanged
    #   :move  bid and ask up a cent with zero sizes: mid +0.01, OFI 0
    defp quote_events(order, cycles) do
      events = List.duplicate(order, cycles) |> List.flatten()

      {ticks, _} =
        events
        |> Enum.with_index()
        |> Enum.map_reduce(100.0, fn
          {:flow, i}, bid -> {quote_tick(i, bid, bid + 0.02, 100, 0), bid}
          {:move, i}, bid -> {quote_tick(i, bid + 0.01, bid + 0.03, 0, 0), bid + 0.01}
        end)

      ticks
    end

    defp values(out), do: Enum.filter(out, &match?(%Decimal{}, &1))

    # One quote per second. OFI comes only from the bid side (bid price
    # fixed, bid size = 10_000 + ofi_k, so each update adds ofi_k - ofi_k-1);
    # mid moves only through the ask price, whose size is 0 so it adds no
    # OFI. The ask sits far above the bid so the book never crosses (a
    # crossed book freezes the mid). `lag` > 0: mid follows OFI by `lag`
    # bars; < 0: mid leads.
    defp lead_lag_quotes(walk, lag) do
      n = length(walk) - abs(lag)
      ofi = if lag >= 0, do: Enum.drop(walk, lag), else: Enum.take(walk, n)
      mid = if lag >= 0, do: Enum.take(walk, n), else: Enum.drop(walk, -lag)

      Enum.zip_with([ofi, mid, Enum.to_list(0..(n - 1))], fn [o, m, i] ->
        quote_tick(i, 100.0, 200.0 + 0.01 * m, 10_000 + o, 0)
      end)
    end

    # A lag-1 random walk gives a strong but not perfect sign over a finite
    # window: at least 90% of windows, and the mean, on the expected side.
    defp mostly?(values, side) do
      values != [] and
        Enum.count(values, &(Decimal.compare(&1, 0) == side)) >= 0.9 * length(values) and
        Decimal.compare(Enum.reduce(values, &Decimal.add/2), 0) == side
    end

    test "quote channels: OFI leading mid gives a positive area, mid leading OFI a negative one" do
      :rand.seed(:exsss, {2, 7, 1})

      for _ <- 1..20 do
        walk = Enum.scan(1..80, 0, fn _, acc -> acc + round(10 * :rand.normal()) end)
        spec = qspec(%{"window" => 40})

        lead = run(spec, lead_lag_quotes(walk, 1)) |> values()
        lag = run(spec, lead_lag_quotes(walk, -1)) |> values()
        assert mostly?(lead, :gt) and mostly?(lag, :lt)
      end
    end

    test "quote channels: cum_ofi keeps the full running sum past the window" do
      spec = qspec(%{"window" => 3, "normalize" => false})
      {:ok, st} = Compute.init(spec)

      st =
        Enum.reduce(quote_events([:flow, :move], 6), st, fn tick, st ->
          {st, _} = Compute.step(spec, st, tick)
          st
        end)

      # 6 flow events of +100, well past a 3-bar window; the very first
      # quote has no prior book, so it contributes nothing
      assert st.cum_ofi == 500.0
      # the newest closed bar (the open one is the last :move)
      {:value, newest} = :queue.peek_r(st.bars)
      assert newest.cum_ofi == 500.0
      assert st.size == 3
    end

    test "quote channels: one-sided updates hold the other side; a quote-free second adds no bar" do
      spec = qspec(%{"window" => 2, "normalize" => false, "output" => "level1", "index" => 1})

      out =
        run(spec, [
          %{at: sec(0), bid: 10.0, bid_size: 5},
          %{at: sec(0, 500), ask: 10.2, ask_size: 5},
          # second 1: bid only, ask held at 10.2 -> mid 10.1
          %{at: sec(1), bid: 10.0, bid_size: 5},
          # seconds 2-4: nothing; second 5: ask only -> mid 10.2
          %{at: sec(5), ask: 10.4, ask_size: 5},
          %{at: sec(6), bid: 10.0, bid_size: 5}
        ])

      # bars: s0 mid 10.1, s1 mid 10.1, s5 mid 10.2 (no bars for s2-s4).
      # Window [s1, s5] mid increment is 0.1.
      assert List.last(out) == Decimal.new("0.10000000")
    end

    test "quote channels: a quote with stale sides is ignored" do
      spec =
        qspec(%{
          "window" => 2,
          "normalize" => false,
          "output" => "level1",
          "index" => 1,
          "max_quote_staleness_ms" => 1000
        })

      out =
        run(spec, [
          quote_tick(0, 10.0, 10.2, 1, 1),
          quote_tick(1, 10.0, 10.2, 1, 1),
          # bid printed 5s after the last ask: not ready, ignored
          %{at: sec(6), bid: 11.0, bid_size: 1},
          %{at: sec(7), ask: 11.2, ask_size: 1},
          quote_tick(8, 10.0, 10.2, 1, 1)
        ])

      # bars: s0, s1, s7 (fresh pair 11.0/11.2, mid 11.1). s6 made no bar.
      assert Enum.at(out, 2) == Enum.at(out, 1)
      assert List.last(out) == Decimal.new("1.00000000")
    end

    test "quote channels mixed with price/volume channels raise; time is allowed" do
      for channels <- [["mid", "price"], ["cum_ofi", "volume"], ["mid", "reference_log_price"]] do
        assert_raise ArgumentError, fn -> Compute.init(qspec(%{"channels" => channels})) end
      end

      assert {:ok, _} = Compute.init(qspec(%{"channels" => ["time", "cum_ofi", "mid"]}))
    end

    test "session_reset clears the bars and restarts cum_ofi; an unbroken session does not" do
      day = fn at -> DateTime.to_date(at) end
      spec = qspec(%{"window" => 3, "session_reset" => day})
      ticks = quote_events([:flow, :move], 4)
      next_day = Enum.map(ticks, &%{&1 | at: DateTime.add(&1.at, 1, :day)})

      {:ok, st} = Compute.init(spec)

      fold = fn ticks, st ->
        Enum.reduce(ticks, st, fn t, st -> elem(Compute.step(spec, st, t), 0) end)
      end

      # 4 flows, the first without a prior book
      st = fold.(ticks, st)
      assert st.cum_ofi == 300.0 and st.size == 3

      # first tick of the next day: everything restarts
      {st2, out} = Compute.step(spec, st, hd(next_day))
      assert out == :warming_up
      assert st2.size == 0 and st2.pending.bucket != nil
      assert st2.cum_ofi == 0.0

      st2 = fold.(tl(next_day), st2)
      assert st2.cum_ofi == 300.0

      # the same ticks without a day change never reset
      st3 =
        fold.(
          ticks ++ Enum.map(ticks, &%{&1 | at: DateTime.add(&1.at, 60)}),
          elem(Compute.init(spec), 1)
        )

      # no reset: the second batch adds to the first. Its first flow comes
      # after a higher bid (a fall, -0 prior size), so it adds 0: 300 + 300
      assert st3.cum_ofi == 600.0 and st3.size == 3
    end

    test "max_window_span_ms reports :warming_up while the window spans too long" do
      spec = qspec(%{"window" => 2, "max_window_span_ms" => 2000, "normalize" => false})

      out =
        run(spec, [
          quote_tick(0, 10.0, 10.2, 1, 1),
          quote_tick(1, 10.1, 10.3, 1, 1),
          quote_tick(2, 10.2, 10.4, 1, 1),
          # 10 seconds later. Each tick closes the previous second's bar:
          # s12 closes s2 (window [s1, s2]), s13 closes s12 (window
          # [s2, s12], 10s span), s14 closes s13 (window [s12, s13])
          quote_tick(12, 10.3, 10.5, 1, 1),
          quote_tick(13, 10.4, 10.6, 1, 1),
          quote_tick(14, 10.5, 10.7, 1, 1)
        ])

      assert [:warming_up, :warming_up, %Decimal{}, %Decimal{}, :warming_up, %Decimal{}] = out
    end

    test "invalid session_reset / max_window_span_ms raise" do
      for bad <- [
            %{"session_reset" => "daily"},
            %{"session_reset" => fn -> 1 end},
            %{"max_window_span_ms" => 0}
          ] do
        assert_raise ArgumentError, fn -> Compute.init(qspec(bad)) end
      end
    end

    property "quote mode: replay/3 equals folding step/2" do
      check all(
              moves <- list_of(member_of([:flow, :move, :both]), min_length: 2, max_length: 40),
              gaps <- list_of(integer(1..3), length: length(moves))
            ) do
        {ticks, _} =
          moves
          |> Enum.zip(Enum.scan(gaps, &(&1 + &2)))
          |> Enum.map_reduce(100.0, fn
            {:flow, s}, bid -> {quote_tick(s, bid, bid + 0.02, 50 + s, 10), bid}
            {:move, s}, bid -> {quote_tick(s, bid + 0.01, bid + 0.03, 10, 20), bid + 0.01}
            {:both, s}, bid -> {quote_tick(s, bid - 0.01, bid + 0.01, 30, s), bid - 0.01}
          end)

        spec = qspec(%{"window" => 4})
        assert run(spec, ticks) == Compute.replay(spec, ticks, only: spec)
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
