defmodule TradingCore.WaveletTransform do
  @moduledoc """
  Discrete Wavelet Transform denoising (Donoho's VisuShrink), the same
  algorithm as the reference Python implementation:

      def denoise_stock_price(price_data, wavelet='coif3', level=3):
          coeffs = pywt.wavedec(price_data, wavelet, mode='per')
          sigma = (1/0.6745) * np.median(np.abs(coeffs[-1] - np.median(coeffs[-1])))
          uthresh = sigma * np.sqrt(2 * np.log(len(price_data)))
          coeffs[1:] = [pywt.threshold(i, value=uthresh, mode='soft') for i in coeffs[1:]]
          return pywt.waverec(coeffs, wavelet, mode='per')

  ported to plain Elixir floats rather than depending on PyWavelets (no
  Elixir equivalent exists). Uses the Daubechies-4 wavelet (`db4`, 8 filter
  taps) instead of `coif3` — a different wavelet family with the same
  vanishing-moments smoothing behavior VisuShrink relies on, chosen here
  for its shorter, well-known filter (easier to transcribe/verify without
  a numpy reference on hand than Coiflet-3's 12 taps).

  `mode='per'` (periodic extension) is what pywt calls it; here that's
  just wraparound indexing (`Integer.mod/2`) at each convolution step —
  no separate boundary-handling code path, since periodic extension is
  the only mode this module implements.

  Every public function works on plain lists of floats, not `Decimal.t()`
  — filter convolution and `:math.log/1`/`:math.sqrt/1` are float
  operations throughout, matching how the Python reference operates on
  numpy float64 arrays. `TradingCore.Signals.wavelet/2` (and, before this
  extraction, `trading_signal`'s own `TradingSignal.Signals.Wavelet`)
  converts to/from `Decimal` at its own boundary — this module stays
  entirely float-only, no `Decimal` dependency at all.

  ## Why this lives in `trading_core`, as its own module

  Moved verbatim from `trading_signal`'s
  `TradingSignal.Signals.WaveletTransform` — the DWT decompose/denoise/
  reconstruct math itself has zero I/O and zero GenServer/PubSub/Repo
  dependency already, so nothing about the algorithm changed in the move.
  It's kept as its own module (not folded into `TradingCore.Signals`)
  because it's substantial and self-contained (a full multi-level forward/
  inverse DWT, not just a thin wrapper) and because
  `TradingCore.Signals.wavelet/2` is the only caller that needs the whole
  pipeline — factoring it out keeps `TradingCore.Signals` itself readable
  as "one function per signal kind" rather than growing a few hundred
  lines of transform internals inline. Living in `trading_core` — rather
  than staying `trading_signal`-only — is what lets a future backtest
  replay engine denoise historical windows with this exact code, unchanged,
  the same "byte-for-byte identical between live and backtest" contract
  `TradingCore.RuleEngine`'s own moduledoc already states as the reason
  that module was extracted.
  """

  # Daubechies-4 (db4) orthogonal wavelet filter coefficients (8 taps).
  # Standard published values (e.g. Daubechies 1992, Table 6.1) — this is
  # the low-pass (scaling) decomposition filter; the others below are all
  # mechanically derived from it via quadrature mirror relationships, not
  # independently sourced numbers.
  @db4_dec_lo [
    -0.010597401785069032,
    0.0328830116668852,
    0.030841381835560764,
    -0.18703481171909309,
    -0.02798376941698385,
    0.6308807679298589,
    0.7148465705529157,
    0.23037781330885523
  ]

  @doc false
  def db4_dec_lo, do: @db4_dec_lo

  # High-pass decomposition filter: reverse the low-pass filter and
  # alternate the sign of every other tap (the standard QMF
  # (quadrature mirror filter) construction for an orthogonal wavelet —
  # this is what makes the detail/approximation split invertible).
  defp dec_hi do
    @db4_dec_lo
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.map(fn {c, i} -> if rem(i, 2) == 0, do: c, else: -c end)
  end

  @doc """
  Multi-level forward DWT with periodic extension, mirroring
  `pywt.wavedec(price_data, 'db4', mode='per')`.

  Returns `[approx | details]` — `approx` is the final-level approximation
  coefficients, `details` is a list of detail-coefficient lists ordered
  coarsest-level-first (index 0 = level `level`'s details, same order
  `pywt.wavedec/3` returns), matching the Python reference's `coeffs` list
  shape (`coeffs[0]` is the approximation, `coeffs[1:]` are details).
  """
  @spec decompose([float()], pos_integer()) :: [[float()]]
  def decompose(signal, level) when is_list(signal) and level > 0 do
    {final_approx, details_coarsest_first} =
      Enum.reduce(1..level, {signal, []}, fn _level, {approx, details} ->
        {new_approx, detail} = single_level_decompose(approx)
        # Each successive iteration decomposes the *previous* iteration's
        # approximation further, i.e. iteration 1 produces the finest-scale
        # detail (highest frequency) and the last iteration produces the
        # coarsest — prepending each new detail as it's produced therefore
        # naturally builds up coarsest-first, matching pywt.wavedec's own
        # `[cA_n, cD_n, cD_n-1, ..., cD_1]` return order. No reversal needed.
        {new_approx, [detail | details]}
      end)

    [final_approx | details_coarsest_first]
  end

  # One level of decompose/2: convolve with both filters, downsample by 2.
  # `length(signal)` must be even for periodic-mode DWT to round-trip
  # exactly — true for every level here as long as the original window
  # size is a power of two (the `Wavelet` signal's fixed 64-sample window
  # satisfies this at every level down to level 4).
  defp single_level_decompose(signal) do
    n = length(signal)
    signal_arr = List.to_tuple(signal)
    filter_len = length(@db4_dec_lo)

    output_len = div(n, 2)

    approx =
      for i <- 0..(output_len - 1) do
        convolve_downsampled(signal_arr, n, @db4_dec_lo, filter_len, i)
      end

    detail =
      for i <- 0..(output_len - 1) do
        convolve_downsampled(signal_arr, n, dec_hi(), filter_len, i)
      end

    {approx, detail}
  end

  # Periodic (circular) convolution at downsampled output index `i`:
  # pywt's 'per' mode convolves the filter against the signal extended
  # periodically (wrapping at the boundary) rather than padding with
  # zeros, then keeps every other output sample starting at index 1 — this
  # is what `Integer.mod/2` on the signal index accomplishes without
  # materializing an extended array.
  defp convolve_downsampled(signal_arr, n, filter, filter_len, i) do
    Enum.reduce(0..(filter_len - 1), 0.0, fn k, acc ->
      signal_index = Integer.mod(2 * i + 1 - k, n)
      acc + Enum.at(filter, k) * elem(signal_arr, signal_index)
    end)
  end

  @doc """
  Inverse DWT with periodic extension, reconstructing a signal from
  `[approx | details]` (as returned by `decompose/2`, optionally with
  `soft_threshold/2` applied to its details first) — mirrors
  `pywt.waverec(coeffs, 'db4', mode='per')`.
  """
  @spec reconstruct([[float()]]) :: [float()]
  def reconstruct([approx | details]) do
    Enum.reduce(details, approx, fn detail, current_approx ->
      single_level_reconstruct(current_approx, detail)
    end)
  end

  # Because db4 (like every orthogonal wavelet) makes the analysis
  # operator's matrix orthonormal, its inverse is exactly its transpose —
  # no separate "reconstruction filter" derivation needed beyond that fact.
  # `convolve_downsampled/5` computes `a[i] = sum_k dec_lo[k] * x[mod(2i+1-k, n)]`
  # (and the same for `d[i]` with `dec_hi`); the transpose of that linear
  # map is, for each output sample `x[j]`, "sum over every `(i, k)` pair
  # that would have read `x[j]` during analysis, weighted by that same
  # filter tap." This is accumulated directly (looping `i` then `k`,
  # scattering into `j = mod(2i+1-k, n)`) rather than re-deriving a
  # closed-form "upsample then convolve" shortcut — a from-scratch
  # closed-form attempt here previously had an off-by-one in the
  # even/odd-tap selection that silently broke reconstruction (caught by
  # this module's own round-trip tests), so this direct, unambiguous
  # transpose is used instead of a cleverer but harder-to-verify formula.
  defp single_level_reconstruct(approx, detail) do
    half = length(approx)
    n = half * 2
    filter_len = length(@db4_dec_lo)
    dec_lo = @db4_dec_lo
    dec_hi = dec_hi()
    approx_arr = List.to_tuple(approx)
    detail_arr = List.to_tuple(detail)

    output = :array.new(n, default: 0.0)

    output =
      Enum.reduce(0..(half - 1), output, fn i, output ->
        a_i = elem(approx_arr, i)
        d_i = elem(detail_arr, i)

        Enum.reduce(0..(filter_len - 1), output, fn k, output ->
          j = Integer.mod(2 * i + 1 - k, n)
          contribution = Enum.at(dec_lo, k) * a_i + Enum.at(dec_hi, k) * d_i
          :array.set(j, :array.get(j, output) + contribution, output)
        end)
      end)

    :array.to_list(output)
  end

  @doc """
  Donoho's VisuShrink universal threshold: `sigma * sqrt(2 * ln(n))`,
  where `sigma` is the finest detail level's coefficients' median absolute
  deviation (scaled by `1/0.6745`, the standard MAD-to-Gaussian-sigma
  correction factor pywt's own reference implementations use) and `n` is
  the original signal length — exactly the Python reference's `sigma`/
  `uthresh` computation.
  """
  @spec universal_threshold(finest_detail :: [float()], signal_length :: pos_integer()) ::
          float()
  def universal_threshold(finest_detail, signal_length) do
    med = median(finest_detail)
    abs_deviations = Enum.map(finest_detail, &abs(&1 - med))
    mad = median(abs_deviations)
    sigma = mad / 0.6745

    sigma * :math.sqrt(2 * :math.log(signal_length))
  end

  @doc """
  Soft-thresholding (`pywt.threshold(x, value, mode: 'soft')`): shrinks
  every coefficient toward zero by `threshold`, clamping at zero rather
  than crossing it — this is what makes VisuShrink denoising smooth
  (continuous in the coefficient value) rather than hard-thresholding's
  jagged all-or-nothing cutoff.
  """
  @spec soft_threshold([float()], float()) :: [float()]
  def soft_threshold(coeffs, threshold) do
    Enum.map(coeffs, fn x ->
      cond do
        x > threshold -> x - threshold
        x < -threshold -> x + threshold
        true -> 0.0
      end
    end)
  end

  @doc """
  Full denoise pipeline matching the Python reference's `denoise_stock_price/2`
  end to end: decompose -> compute the universal threshold from the
  finest-level details -> soft-threshold every detail level (the
  approximation coefficients, `coeffs[0]`, are never thresholded, same as
  the Python reference's `coeffs[1:]` slice) -> reconstruct.

  Returns the full reconstructed series, same length as `signal` — the
  caller (`TradingCore.Signals.wavelet/2`) takes just the last point as
  the current "denoised trend" value.
  """
  @spec denoise([float()], pos_integer()) :: [float()]
  def denoise(signal, level) do
    [approx | details] = decompose(signal, level)

    # The finest (highest-frequency) detail level is last in pywt's
    # coeffs[1:] order (coarsest-first) — same as this module's own
    # decompose/2 doc, so List.last/1 here mirrors the Python reference's
    # coeffs[-1].
    finest_detail = List.last(details)
    threshold = universal_threshold(finest_detail, length(signal))

    thresholded_details = Enum.map(details, &soft_threshold(&1, threshold))

    reconstruct([approx | thresholded_details])
  end

  defp median(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 0 do
      (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
    else
      Enum.at(sorted, mid)
    end
  end
end
