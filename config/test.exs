import Config

alias EctoLiteFS.Test.Repo

config :ecto_litefs, Repo,
  database: Path.expand("../test/test.db", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox,
  show_sensitive_data_on_connection_error: true

config :ecto_litefs, ecto_repos: [Repo]

config :logger, level: :warning
