# EctoLiteFS

LiteFS-aware Ecto middleware for automatic write forwarding in distributed SQLite clusters.

EctoLiteFS detects which node is the current LiteFS primary and automatically forwards
write operations to it, allowing replicas to handle reads locally while writes are
transparently routed to the primary.

## Installation

Add `ecto_litefs` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ecto_litefs, "~> 0.1.0"}
  ]
end
```

## Usage

Add the supervisor to your application's supervision tree, after your Repo:

```elixir
children = [
  MyApp.Repo,
  {EctoLiteFS.Supervisor,
    repo: MyApp.Repo,
    primary_file: "/litefs/.primary",
    poll_interval: 30_000,
    event_stream_url: "http://localhost:20202/events"
  }
]
```

## Configuration Options

* `:repo` - Required. The Ecto Repo module to track.
* `:primary_file` - Path to LiteFS `.primary` file. Default: `"/litefs/.primary"`
* `:poll_interval` - Filesystem poll interval in ms. Default: `30_000`
* `:event_stream_url` - LiteFS HTTP events endpoint. Default: `"http://localhost:20202/events"`
* `:table_name` - Database table for primary tracking. Default: `"_ecto_litefs_primary"`
* `:cache_ttl` - Cache TTL in ms. Default: `5_000`
* `:erpc_timeout` - Timeout for RPC calls to primary. Default: `15_000`

## How It Works

EctoLiteFS uses multiple detection methods to determine primary status:

1. **Filesystem polling** - Checks for the presence of LiteFS's `.primary` file
2. **Event streaming** - Subscribes to LiteFS's HTTP event stream for real-time updates
3. **Database tracking** - Stores primary node information in a replicated table

When a write operation is detected on a replica node, it's automatically forwarded
to the primary node via `:erpc.call/4`.

## Testing

### Unit Tests

```bash
mix test
```

### End-to-End Tests

The E2E test suite validates the full LiteFS cluster behavior including write forwarding
and automatic failover. It requires Docker with privileged mode (for FUSE filesystem).

```bash
cd e2e
./run_tests.sh
```

The E2E tests spin up a Docker Compose cluster with:
- **Consul** - Leader election coordinator
- **Primary node** - LiteFS primary with Elixir app
- **Replica node** - LiteFS replica with Elixir app

Test scenarios:
1. Cluster status verification
2. Write to primary, replicate to replica
3. Write forwarding from replica to primary
4. Primary failover - replica promoted, data preserved

## License

MIT License - see [LICENSE](LICENSE) for details.
