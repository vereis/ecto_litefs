defmodule EctoLiteFS do
  @moduledoc """
  LiteFS-aware Ecto middleware for automatic write forwarding in distributed SQLite clusters.

  EctoLiteFS detects which node is the current LiteFS primary and automatically forwards
  write operations to it, allowing replicas to handle reads locally while writes are
  transparently routed to the primary.

  ## Usage

  Add the supervisor to your application's supervision tree, after your Repo:

      children = [
        MyApp.Repo,
        {EctoLiteFS.Supervisor,
          name: :my_litefs,
          repo: MyApp.Repo,
          primary_file: "/litefs/.primary",
          poll_interval: 30_000,
          event_stream_url: "http://localhost:20202/events"
        }
      ]

  ## Configuration Options

  * `:name` - Required. Unique identifier for this EctoLiteFS instance.
  * `:repo` - Required. The Ecto Repo module to track.
  * `:primary_file` - Path to LiteFS `.primary` file. Default: `"/litefs/.primary"`
  * `:poll_interval` - Filesystem poll interval in ms. Default: `30_000`
  * `:event_stream_url` - LiteFS HTTP events endpoint. Default: `"http://localhost:20202/events"`
  * `:table_name` - Database table for primary tracking. Default: `"_ecto_litefs_primary"`
  * `:cache_ttl` - Cache TTL in ms. Default: `5_000`
  """
end
