defmodule TradingCore.Signals.Signature do
  @moduledoc """
  The truncated path signature (levels 1 and 2) of a piecewise-linear
  multi-channel path, and the Lévy area read from it. Backs the
  `:signature` kind in `TradingCore.Signal.Compute`; also usable directly
  for research (`level2_flat/1` gives the full feature vector).

  A path is a list of points, oldest first, each a list of `d` floats
  (one per channel). With increments `dX_k = X_k − X_{k−1}`, the level-1
  term is the total increment and the level-2 term is accumulated with
  the exact formula for a piecewise-linear path:

      S2[i][j] += S1_prev[i] · dX[j] + ½ · dX[i] · dX[j]
      S1[i]    += dX[i]

  The **Lévy area** of channels `(i, j)` is `½ (S2[i][j] − S2[j][i])`: the
  signed area between the path and its chord in the `(i, j)` plane,
  positive when the path turns counter-clockwise, i.e. when channel `i`
  moves first and `j` follows (a lead–lag effect).

  Pure and float-based (the work is O(N·d²) per window, recomputed in
  full each time; no Chen-identity updates). Callers that store a result
  round it (`Compute` returns `Decimal`s rounded to 8 places).
  """

  @type path :: [[float()]]
  @type sig :: %{level1: [float()], level2: [[float()]]}

  @doc "Levels 1 and 2 of `path`'s signature. A path of fewer than two points has a zero signature."
  @spec signature(path()) :: sig()
  def signature([]), do: zero(0)
  def signature([first | _] = path), do: path |> increments() |> accumulate(zero(length(first)))

  @doc "`½ (S2[i][j] − S2[j][i])`, channels zero-indexed."
  @spec levy_area(sig(), non_neg_integer(), non_neg_integer()) :: float()
  def levy_area(%{level2: s2}, i, j), do: 0.5 * (at(s2, i, j) - at(s2, j, i))

  @doc "The level-2 terms flattened row by row: `[S2[0][0], S2[0][1], …]`."
  @spec level2_flat(sig()) :: [float()]
  def level2_flat(%{level2: s2}), do: List.flatten(s2)

  @doc """
  Each channel z-scored within the path: `(x − mean) / sd`, population
  sd. A flat channel (sd 0) becomes all zeros. An affine rescaling per
  channel, so a Lévy area keeps its sign.
  """
  @spec normalize(path()) :: path()
  def normalize([]), do: []

  def normalize(path) do
    path
    |> transpose()
    |> Enum.map(fn channel ->
      n = length(channel)
      mean = Enum.sum(channel) / n
      sd = :math.sqrt(Enum.sum(Enum.map(channel, &((&1 - mean) ** 2))) / n)

      if sd == 0.0,
        do: Enum.map(channel, fn _ -> 0.0 end),
        else: Enum.map(channel, &((&1 - mean) / sd))
    end)
    |> transpose()
  end

  ## ---------------------------------------------------------------------

  defp zero(d),
    do: %{level1: List.duplicate(0.0, d), level2: List.duplicate(List.duplicate(0.0, d), d)}

  defp increments(path) do
    path
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [prev, curr] -> Enum.zip_with(curr, prev, &(&1 - &2)) end)
  end

  defp accumulate(increments, sig) do
    Enum.reduce(increments, sig, fn dx, %{level1: s1, level2: s2} ->
      s2 =
        Enum.zip_with(s2, Enum.zip(s1, dx), fn row, {s1_i, dx_i} ->
          Enum.zip_with(row, dx, fn s2_ij, dx_j -> s2_ij + s1_i * dx_j + 0.5 * dx_i * dx_j end)
        end)

      %{level1: Enum.zip_with(s1, dx, &(&1 + &2)), level2: s2}
    end)
  end

  defp at(matrix, i, j), do: matrix |> Enum.at(i) |> Enum.at(j)

  defp transpose(rows), do: rows |> Enum.zip() |> Enum.map(&Tuple.to_list/1)
end
