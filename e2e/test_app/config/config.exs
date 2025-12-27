import Config

config :logger, level: :info

config :test_app, TestApp.Repo,
  database: System.get_env("DATABASE_PATH", "/litefs/test.db"),
  pool_size: 5

config :test_app, :litefs,
  primary_file: "/litefs/.primary",
  # Always connect to local LiteFS instance - it knows about primary changes
  event_stream_url: "http://localhost:20202/events"

config :test_app,
  ecto_repos: [TestApp.Repo]
