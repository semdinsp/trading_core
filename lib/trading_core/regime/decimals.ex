defmodule TradingCore.Regime.Decimals do
  @moduledoc false
  # Non-raising number parsing shared by Playbook, Exposure and
  # AllocationGate. These run inside trading_live's guardian
  # handle_call, where a raise takes the whole book down, so bad input
  # comes back as :error for the caller to fail closed on.

  @doc "Parses a finite number. Floats are accepted unless `floats: false`."
  @spec parse(term(), keyword()) :: {:ok, Decimal.t()} | :error
  def parse(value, opts \\ [])

  def parse(%Decimal{} = d, _opts) do
    if Decimal.inf?(d) or Decimal.nan?(d), do: :error, else: {:ok, d}
  end

  def parse(value, _opts) when is_integer(value), do: {:ok, Decimal.new(value)}

  def parse(value, opts) when is_float(value) do
    if Keyword.get(opts, :floats, true), do: {:ok, Decimal.from_float(value)}, else: :error
  end

  def parse(value, opts) when is_binary(value) do
    case Decimal.parse(String.trim(value)) do
      {d, ""} -> parse(d, opts)
      _ -> :error
    end
  end

  def parse(_value, _opts), do: :error

  @doc "`parse/2`, additionally requiring the value to be `>= 0` (`:non_neg`) or `> 0` (`:pos`)."
  @spec parse(term(), :non_neg | :pos, keyword()) :: {:ok, Decimal.t()} | :error
  def parse(value, bound, opts) do
    with {:ok, d} <- parse(value, opts),
         true <- in_bound?(d, bound) do
      {:ok, d}
    else
      _ -> :error
    end
  end

  defp in_bound?(d, :non_neg), do: Decimal.compare(d, 0) != :lt
  defp in_bound?(d, :pos), do: Decimal.compare(d, 0) == :gt
end
