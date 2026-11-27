defmodule TradingCore.Signals.ChangeZscoreTest do
  use ExUnit.Case, async: true

  alias TradingCore.Signals.ChangeZscore

  describe "change/3" do
    test "exact keys only" do
      samples = %{100 => 1.5, 160 => 2.0}
      assert ChangeZscore.change(samples, 160, 60) == 0.5
      assert ChangeZscore.change(samples, 161, 60) == nil
      assert ChangeZscore.change(samples, 160, 59) == nil
    end
  end

  describe "zscore/5" do
    # A series whose 1-minute change alternates +1 / -1 around a drift,
    # so 1-minute changes have mean 0 and a real spread.
    defp zigzag(range), do: Map.new(range, &{&1, if(rem(&1, 2) == 0, do: 0.0, else: 1.0)})

    test "z of the current change against the trailing ones" do
      samples = zigzag(0..200)
      # Reference: changes at 100..199 (lookback 100), alternating -1/+1.
      reference = for m <- 100..199, do: samples[m] - samples[m - 1]
      mean = Enum.sum(reference) / 100
      sd = :math.sqrt(Enum.sum(Enum.map(reference, &((&1 - mean) ** 2))) / 99)

      samples = Map.put(samples, 200, 3.0)
      assert {:ok, z} = ChangeZscore.zscore(samples, 200, 1, 100, 50)
      assert_in_delta z, (3.0 - samples[199] - mean) / sd, 1.0e-12
    end

    test "the current minute is not in its own reference set" do
      # Minutes 1..9 hold the +/-1 reference changes (stdev ~1.05). The
      # 999 jump at 10 scores ~950; counted in its own reference set it
      # would inflate the stdev to ~300 and score ~3.
      samples = zigzag(0..9) |> Map.put(10, 1000.0)
      assert {:ok, z} = ChangeZscore.zscore(samples, 10, 1, 10, 9)
      assert z > 900
    end

    test ":no_change when the current change is undefined" do
      assert ChangeZscore.zscore(%{100 => 1.0}, 100, 60, 1000, 1) == {:error, :no_change}
    end

    test ":warming_up below min_samples, and always below 2" do
      # Changes are defined at minutes 1..19: 19 reference changes.
      samples = zigzag(0..20)
      assert ChangeZscore.zscore(samples, 20, 1, 100, 20) == {:error, :warming_up}
      assert {:ok, _} = ChangeZscore.zscore(samples, 20, 1, 100, 19)

      # One reference change: no sample stdev, whatever min_samples says.
      assert ChangeZscore.zscore(%{0 => 0.0, 1 => 1.0, 2 => 3.0}, 2, 1, 1, 1) ==
               {:error, :warming_up}
    end

    test "gaps reduce the reference count" do
      samples = zigzag(0..20) |> Map.drop([5, 6])
      # Of the 19 changes at 1..19, those at 5, 6 and 7 are gone: 16 remain.
      assert ChangeZscore.zscore(samples, 20, 1, 100, 17) == {:error, :warming_up}
      assert {:ok, _} = ChangeZscore.zscore(samples, 20, 1, 100, 16)
    end

    test ":flat when every reference change is the same" do
      samples = Map.new(0..100, &{&1, &1 * 0.5})
      assert ChangeZscore.zscore(samples, 100, 1, 50, 10) == {:error, :flat}
    end

    test ":flat on jitter below the relative floor" do
      samples = Map.new(0..100, &{&1, &1 * 1.0 + if(rem(&1, 2) == 0, do: 0.0, else: 1.0e-9)})
      assert ChangeZscore.zscore(samples, 100, 1, 50, 10) == {:error, :flat}
    end
  end

  describe "prune/3" do
    test "keeps keys >= minute - keep_min" do
      samples = Map.new(0..10, &{&1, 1.0})
      assert samples |> ChangeZscore.prune(10, 3) |> Map.keys() |> Enum.sort() == [7, 8, 9, 10]
    end

    test "keeping lookback + window leaves zscore unchanged" do
      samples = Map.new(0..500, &{&1, :math.sin(&1 / 7)})
      pruned = ChangeZscore.prune(samples, 500, 100 + 30)

      assert ChangeZscore.zscore(pruned, 500, 30, 100, 50) ==
               ChangeZscore.zscore(samples, 500, 30, 100, 50)
    end
  end
end
