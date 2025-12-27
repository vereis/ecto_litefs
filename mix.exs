defmodule EctoLiteFS.MixProject do
  use Mix.Project

  def project do
    [
      aliases: aliases(),
      app: :ecto_litefs,
      version: "1.0.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      elixirc_options: [warnings_as_errors: true],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        plt_add_apps: [:mix, :ex_unit]
      ],
      preferred_cli_env: [
        test: :test,
        "test.watch": :test,
        coveralls: :test,
        "coveralls.html": :test,
        "coveralls.github": :test,
        precommit: :test
      ],
      test_coverage: [tool: ExCoveralls],
      package: package(),
      description: description(),
      source_url: "https://github.com/vereis/ecto_litefs",
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Runtime dependencies
      {:ecto_sql, "~> 3.11"},
      {:ecto_sqlite3, "~> 0.17"},
      {:ecto_middleware, "~> 2.0.1"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},

      # Lint dependencies
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:styler, "~> 1.2", only: [:dev, :test], runtime: false},

      # Test dependencies
      {:briefly, "~> 0.5", only: :test},
      {:mimic, "~> 2.2", only: :test},
      {:mix_test_watch, "~> 1.1", only: :test, runtime: false},
      {:excoveralls, "~> 0.18", only: :test, runtime: false},

      # Misc dependencies
      {:ex_doc, "~> 0.14", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      lint: [
        "deps.unlock --unused",
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "dialyzer"
      ],
      precommit: [
        "deps.unlock --unused",
        "format",
        "compile --warnings-as-errors",
        "credo --strict",
        "dialyzer",
        "test"
      ]
    ]
  end

  defp description do
    """
    LiteFS-aware Ecto middleware for automatic write forwarding in distributed SQLite clusters.
    """
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/vereis/ecto_litefs"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"]
    ]
  end
end
