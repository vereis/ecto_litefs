defmodule TestApp.MixProject do
  use Mix.Project

  def project do
    [
      app: :test_app,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {TestApp.Application, []}
    ]
  end

  defp deps do
    [
      {:ecto_litefs, path: "../.."},
      {:plug_cowboy, "~> 2.6"},
      {:jason, "~> 1.4"}
    ]
  end
end
