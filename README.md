<p align="center">
  <img src="https://github.com/user-attachments/assets/fde2b47f-d853-4ee3-bdad-54a18b852730" alt="EctoLiteFS" style="max-width: 100%; height: auto;" />
</p>

# EctoLiteFS

LiteFS-aware Ecto middleware for automatic write forwarding in distributed SQLite clusters.

EctoLiteFS detects which node is the current LiteFS primary and automatically forwards
write operations to it, allowing replicas to handle reads locally while writes are
transparently routed to the primary.

> **Built on [EctoMiddleware](https://hex.pm/packages/ecto_middleware):** EctoLiteFS includes
> EctoMiddleware as a dependency, so installing `ecto_litefs` gives you everything you need!

## Features

- **Automatic write forwarding** - Writes on replicas are transparently forwarded to primary
- **Local reads** - Replicas handle reads locally for low latency
- **Multiple detection methods** - Filesystem polling + HTTP event stream + database tracking
- **Zero-config in dev/test** - Gracefully degrades when LiteFS is not present
- **Minimal setup** - Just add middleware and a supervisor to your app
- **Works with multiple repos** - Can track any number of Ecto repos in the same app
- **Telemetry integration** - Monitor write forwarding performance and failures

## Installation

Add `ecto_litefs` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ecto_litefs, "~> 1.0"}
  ]
end
```

## Quick Start

### 1. Add to Supervision Tree

Add `EctoLiteFS.Supervisor` to your application, **after** your Repo:

```elixir
defmodule MyApp.Application do
  def start(_type, _args) do
    children = [
      MyApp.Repo,
      {EctoLiteFS.Supervisor,
        repo: MyApp.Repo,
        primary_file: "/litefs/.primary",
        poll_interval: 30_000,
        event_stream_url: "http://localhost:20202/events"
      }
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

### 2. Add Middleware to Repo

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo, otp_app: :my_app
  use EctoMiddleware.Repo  # Included with ecto_litefs!

  @impl EctoMiddleware.Repo
  def middleware(_action, _resource) do
    [EctoLiteFS.Middleware] # Add anywhere in your middleware stack
  end
end
```

### 3. Use Your Repo Normally

```elixir
# On primary node - executes locally
MyApp.Repo.insert!(%User{name: "Alice"})

# On replica node - automatically forwarded to primary
MyApp.Repo.insert!(%User{name: "Bob"})

# Reads always execute locally (low latency!)
MyApp.Repo.all(User)
```

That's it! Writes are automatically forwarded when running on a replica.

> **Future Plans:** Support for forwarding transactions and bulk operations is planned for future releases.

## Configuration Options

All options are configured when starting the supervisor:

* `:repo` - **Required**. The Ecto Repo module to track.
* `:primary_file` - Path to LiteFS `.primary` file. Default: `"/litefs/.primary"`
* `:poll_interval` - Filesystem poll interval in ms. Default: `30_000`
* `:event_stream_url` - LiteFS HTTP events endpoint. Default: `"http://localhost:20202/events"`
* `:table_name` - Database table for primary tracking. Default: `"_ecto_litefs_primary"`
* `:cache_ttl` - Cache TTL in ms. Default: `5_000`
* `:erpc_timeout` - Timeout for RPC calls to primary. Default: `15_000`

### Minimal Configuration

For most use cases, you only need to specify `:repo`:

```elixir
{EctoLiteFS.Supervisor, repo: MyApp.Repo}
```

All other options use sensible defaults that work with standard LiteFS configurations.

## How It Works

EctoLiteFS uses multiple detection methods to determine primary status:

1. **Filesystem polling** - Checks for the presence of LiteFS's `.primary` file
2. **Event streaming** - Subscribes to LiteFS's HTTP event stream for real-time updates
3. **Database tracking** - Stores primary node information in a replicated table

When a write operation is detected on a replica node, it's automatically forwarded
to the primary node via `:erpc.call/4`.

By default, both filesystem polling and event streaming are enabled for robust detection, but either
of these can be disabled if desired.

### Architecture

```
┌─────────────────────┐         ┌─────────────────────┐
│   Primary Node      │         │   Replica Node      │
│                     │         │                     │
│  ┌──────────────┐   │         │  ┌──────────────┐   │
│  │ Repo.insert  │   │  :erpc  │  │ Repo.insert  │───┼──┐
│  └──────┬───────┘   │ ◄───────┼──│   (forwarded)│   │  │
│         │           │         │  └──────────────┘   │  │
│    ┌────▼────┐      │         │                     │  │
│    │ SQLite  │◄─────┼─────────┼─► Reads happen      │  │
│    │ (write) │      │ replicate│   locally          │  │
│    └─────────┘      │         │                     │  │
└─────────────────────┘         └─────────────────────┘  │
                                                         │
                    Middleware detects write ────────────┘
                    and forwards to primary
```

## Development & Testing

EctoLiteFS gracefully handles environments where LiteFS is not present:

- **Production (with LiteFS):** Forwards writes to primary, reads from replica
- **Development/Test (no LiteFS):** Executes all operations locally

This means you can add the middleware to your Repo without any conditional logic -
it will "just work" in all environments!

## Monitoring with Telemetry

EctoLiteFS emits telemetry events for observability:

```elixir
# Monitor slow write forwards
:telemetry.attach(
  "log-slow-forwards",
  [:ecto_litefs, :forward, :stop],
  fn _event, %{duration: duration}, %{repo: repo, action: action}, _config ->
    if duration > 5_000_000 do  # 5ms
      Logger.warning("Slow forward: #{action} took #{duration}ns")
    end
  end,
  nil
)

# Track forwarding failures
:telemetry.attach(
  "track-forward-errors",
  [:ecto_litefs, :forward, :exception],
  fn _event, _measurements, %{repo: repo, reason: reason}, _config ->
    Logger.error("Forward failed: #{inspect(reason)}")
  end,
  nil
)
```

Available events:
- `[:ecto_litefs, :forward, :start]` - Write forwarding initiated
- `[:ecto_litefs, :forward, :stop]` - Forwarding completed successfully
- `[:ecto_litefs, :forward, :exception]` - Forwarding failed

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

## Similar Projects

- **[litefs](https://hex.pm/packages/litefs)** - The original LiteFS library for Elixir by [@sheertj](https://git.sr.ht/~sheertj). 
  Uses a repo wrapper approach where you rename your repo to `MyApp.Repo.Local` and create a new 
  `MyApp.Repo` that proxies writes, and relies on filesystem polling only. EctoLiteFS differs by 
  using middleware instead (so your existing repo stays unchanged), and adds HTTP event streaming 
  for faster primary detection.

## License

MIT License - see [LICENSE](LICENSE) for details.
