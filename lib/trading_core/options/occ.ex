defmodule TradingCore.Options.Occ do
  @moduledoc """
  Parses OCC-style option symbols, e.g. `"SPY261001C00550000"`:

      root   SPY       1-6 characters (letters/digits), e.g. "SPXW", "SPY"
      expiry 261001    YYMMDD, read as 20YY
      right  C         C (call) or P (put)
      strike 00550000  strike × 1000, 8 digits -> 550.000

  The last 15 characters are always expiry + right + strike, so the
  root is whatever precedes them. That keeps roots that contain digits
  (adjusted roots such as `"SPY1"`) unambiguous. Padding spaces between
  root and expiry, as in the full 21-character OCC form
  (`"SPY   261001C00550000"`), are trimmed.

  Pure and never raises: anything that doesn't match, including an
  impossible date such as `261301`, is `:error`.
  """

  @type parsed :: %{root: String.t(), expiry: Date.t(), right: :call | :put, strike: Decimal.t()}

  @tail ~r/^(\d{2})(\d{2})(\d{2})([CP])(\d{8})$/
  @root ~r/^[A-Z0-9]{1,6}$/

  @doc "Parses one OCC-style option symbol. See the moduledoc."
  @spec parse(term()) :: {:ok, parsed()} | :error
  def parse(symbol) when is_binary(symbol) and byte_size(symbol) > 15 do
    {root, tail} = String.split_at(symbol, -15)
    root = String.trim_trailing(root)

    with true <- Regex.match?(@root, root),
         [_, yy, mm, dd, right, strike] <- Regex.run(@tail, tail),
         {:ok, expiry} <- Date.new(2000 + int(yy), int(mm), int(dd)) do
      {:ok,
       %{
         root: root,
         expiry: expiry,
         right: if(right == "C", do: :call, else: :put),
         strike: Decimal.new(1, int(strike), -3)
       }}
    else
      _ -> :error
    end
  end

  def parse(_symbol), do: :error

  defp int(digits), do: String.to_integer(digits)
end
