defmodule TradingCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :trading_core,
      version: "0.4.1",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      # Shared fixtures that test files Code.require_file/2 themselves.
      test_ignore_filters: [&String.starts_with?(&1, "test/support/")]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:decimal, "~> 3.0"},
      {:tzdata, "~> 1.1"},
      {:stream_data, "~> 1.1", only: [:dev, :test]}
    ]
  end
end
