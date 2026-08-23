defmodule TradingCore.WaveletTransformTest do
  use ExUnit.Case, async: true

  alias TradingCore.WaveletTransform

  describe "decompose/2 + reconstruct/1 (perfect reconstruction)" do
    test "round-trips a ramp signal exactly at level 3" do
      signal = Enum.map(1..64, &(&1 * 1.0))

      reconstructed =
        signal
        |> WaveletTransform.decompose(3)
        |> WaveletTransform.reconstruct()

      assert_close_list(reconstructed, signal)
    end

    test "round-trips a noisy sine signal exactly at level 4" do
      signal =
        for i <- 0..63 do
          :math.sin(i / 4) * 10 + :rand.uniform() * 0.01
        end

      reconstructed =
        signal
        |> WaveletTransform.decompose(4)
        |> WaveletTransform.reconstruct()

      assert_close_list(reconstructed, signal)
    end

    test "round-trips a constant signal exactly" do
      signal = List.duplicate(42.0, 64)

      reconstructed =
        signal
        |> WaveletTransform.decompose(3)
        |> WaveletTransform.reconstruct()

      assert_close_list(reconstructed, signal)
    end

    test "decompose/2 halves length at each level" do
      signal = Enum.map(1..64, &(&1 * 1.0))
      [approx | details] = WaveletTransform.decompose(signal, 3)

      assert length(approx) == 8
      assert Enum.map(details, &length/1) == [8, 16, 32]

      # coarsest-first, matching pywt.wavedec's [cA_n, cD_n, ..., cD_1] order
    end
  end

  describe "soft_threshold/2" do
    test "shrinks positive and negative coefficients toward zero" do
      assert WaveletTransform.soft_threshold([5.0, -5.0, 1.0, -1.0], 2.0) == [
               3.0,
               -3.0,
               0.0,
               0.0
             ]
    end

    test "never crosses zero" do
      [result] = WaveletTransform.soft_threshold([0.5], 2.0)
      assert result == 0.0
    end
  end

  describe "universal_threshold/2" do
    test "is zero for all-zero detail coefficients" do
      assert WaveletTransform.universal_threshold(List.duplicate(0.0, 8), 64) == 0.0
    end

    test "scales with signal_length via sqrt(2 ln n)" do
      detail = [1.0, -1.0, 2.0, -2.0, 0.5, -0.5, 1.5, -1.5]

      small = WaveletTransform.universal_threshold(detail, 8)
      large = WaveletTransform.universal_threshold(detail, 1024)

      assert large > small
    end
  end

  describe "denoise/2" do
    test "smooths high-frequency noise while preserving a trend's scale" do
      trend = for i <- 0..63, do: i * 0.5

      # Deterministic alternating +/- noise (not :rand) so this test isn't
      # flaky: VisuShrink's threshold is derived from the noisy signal's
      # own finest-detail MAD, so a tiny noise amplitude relative to the
      # trend's own scale can fall under that threshold and not get
      # shrunk at all — this fixed, clearly-high-frequency perturbation
      # (alternating sign every sample, comparable in scale to the
      # trend's own per-step increment) is unambiguously the kind of
      # noise VisuShrink is meant to remove.
      noisy =
        trend
        |> Enum.with_index()
        |> Enum.map(fn {v, i} -> v + if(rem(i, 2) == 0, do: 1.0, else: -1.0) end)

      denoised = WaveletTransform.denoise(noisy, 3)

      assert length(denoised) == length(noisy)

      # Denoising should reduce total deviation from the underlying trend
      # versus the noisy input itself.
      noisy_error = sum_abs_diff(noisy, trend)
      denoised_error = sum_abs_diff(denoised, trend)

      assert denoised_error <= noisy_error
    end

    test "returns a series the same length as the input" do
      signal = Enum.map(1..64, &(&1 * 1.0))
      denoised = WaveletTransform.denoise(signal, 4)

      assert length(denoised) == 64
    end
  end

  defp sum_abs_diff(a, b) do
    a
    |> Enum.zip(b)
    |> Enum.reduce(0.0, fn {x, y}, acc -> acc + abs(x - y) end)
  end

  defp assert_close_list(actual, expected, tolerance \\ 1.0e-9) do
    assert length(actual) == length(expected)

    Enum.zip(actual, expected)
    |> Enum.each(fn {a, e} ->
      assert_in_delta a, e, tolerance
    end)
  end
end
