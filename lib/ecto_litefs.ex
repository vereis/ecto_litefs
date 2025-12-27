defmodule EctoLiteFS do
  @moduledoc """
  LiteFS-aware Ecto middleware for automatic write forwarding in distributed SQLite clusters.

  EctoLiteFS detects which node is the current LiteFS primary and automatically forwards
  write operations to it, allowing replicas to handle reads locally while writes are
  transparently routed to the primary.

  > **Built on EctoMiddleware:** EctoLiteFS is powered by [EctoMiddleware](https://hex.pm/packages/ecto_middleware),
  > which is included as a dependency. Installing `ecto_litefs` gives you everything you need!

  ## Quick Example

      # 1. Add EctoLiteFS supervisor to your application
      defmodule MyApp.Application do
        def start(_type, _args) do
          children = [
            MyApp.Repo,
            {EctoLiteFS.Supervisor, repo: MyApp.Repo}
          ]

          Supervisor.start_link(children, strategy: :one_for_one)
        end
      end

      # 2. Add middleware to your Repo
      defmodule MyApp.Repo do
        use Ecto.Repo, otp_app: :my_app
        use EctoMiddleware.Repo

        @impl EctoMiddleware.Repo
        def middleware(_action, _resource) do
          [EctoLiteFS.Middleware]
        end
      end

      # 3. Use your Repo normally - writes are automatically forwarded!
      # On primary node:
      MyApp.Repo.insert!(%User{name: "Alice"})  # Executes locally

      # On replica node:
      MyApp.Repo.insert!(%User{name: "Bob"})    # Forwarded to primary via :erpc
      MyApp.Repo.all(User)                      # Reads locally from replica

  ## Setup

  ### 1. Add to Supervision Tree

  Add `EctoLiteFS.Supervisor` to your application's supervision tree, **after** your Repo:

      children = [
        MyApp.Repo,
        {EctoLiteFS.Supervisor,
          repo: MyApp.Repo,
          primary_file: "/litefs/.primary",
          poll_interval: 30_000,
          event_stream_url: "http://localhost:20202/events"
        }
      ]

  ### 2. Add Middleware to Repo

  EctoLiteFS uses [EctoMiddleware](https://hex.pm/packages/ecto_middleware) (included as a dependency):

      defmodule MyApp.Repo do
        use Ecto.Repo, otp_app: :my_app
        use EctoMiddleware.Repo  # Comes with ecto_litefs!

        @impl EctoMiddleware.Repo
        def middleware(_action, _resource) do
          [EctoLiteFS.Middleware]  # Add alongside other middleware if needed
        end
      end

  That's it! Writes will automatically be forwarded to the primary node when running on a replica.

  ## Configuration Options

  * `:repo` - Required. The Ecto Repo module to track (also serves as the unique identifier).
  * `:primary_file` - Path to LiteFS `.primary` file. Default: `"/litefs/.primary"`
  * `:poll_interval` - Filesystem poll interval in ms. Default: `30_000`
  * `:event_stream_url` - LiteFS HTTP events endpoint. Default: `"http://localhost:20202/events"`
  * `:table_name` - Database table for primary tracking. Default: `"_ecto_litefs_primary"`
  * `:cache_ttl` - Cache TTL in ms. Default: `5_000`
  * `:erpc_timeout` - Timeout for `:erpc` calls when forwarding writes to primary. Default: `15_000`

  ## How It Works

  EctoLiteFS uses multiple detection methods to determine primary status:

  1. **Filesystem polling** - Checks for the presence of LiteFS's `.primary` file
  2. **Event streaming** - Subscribes to LiteFS's HTTP event stream for real-time updates
  3. **Database tracking** - Stores primary node information in a replicated table

  When a write operation is detected on a replica node, it's automatically forwarded
  to the primary node via `:erpc.call/4`.

  ### Primary Detection

  The Tracker process maintains an ETS cache of the current primary node, refreshed from
  the database when stale. This ensures low-latency reads while maintaining consistency.

  ### Write Forwarding

  The middleware intercepts write operations (insert, update, delete) and checks if the
  current node is the primary. If not, it forwards the operation to the primary using
  `:erpc.call/4` with a configurable timeout.

  ## Development & Test Mode

  When `EctoLiteFS.Supervisor` is not started (e.g., in dev/test), the middleware
  automatically passes through to local execution. This means you can add the
  middleware to your Repo and it will "just work" in all environments:

  - **Production (with LiteFS):** Forwards writes to primary node
  - **Development/Test (no LiteFS):** Executes writes locally

  ## Telemetry Events

  EctoLiteFS emits telemetry events for observability:

  - `[:ecto_litefs, :forward, :start]` - Write forwarding initiated
  - `[:ecto_litefs, :forward, :stop]` - Forwarding completed successfully
  - `[:ecto_litefs, :forward, :exception]` - Forwarding failed

  All events include metadata: `%{repo: repo, action: action, primary_node: node}`

  ### Example: Monitoring Write Forwarding

      :telemetry.attach(
        "log-write-forwards",
        [:ecto_litefs, :forward, :stop],
        fn _event, %{duration: duration}, %{repo: repo, action: action}, _config ->
          Logger.info("Forwarded \#{action} to primary in \#{duration}ns")
        end,
        nil
      )

  ## Error Handling

  - `{:error, :primary_unavailable}` - No primary node is known (cluster may be initializing)
  - `{:error, {:erpc, :timeout, node}}` - RPC call timed out
  - `{:error, {:erpc, :noconnection, node}}` - Primary node is unreachable

  > #### Timeout Warning {: .warning}
  >
  > A timeout error does **not** mean the write failed. The primary node may have
  > completed the write before the timeout occurred. Design your application to
  > handle this uncertainty (e.g., idempotent writes, conflict resolution).

  ## Limitations

  - **Transactions:** Write forwarding within `Repo.transaction/2` is not currently
    supported. Transactions must execute entirely on the primary node.

  ## Public API

  While the middleware handles most operations automatically, you can also use the
  public API for direct control:

      # Check if current node is primary
      EctoLiteFS.is_primary?(MyApp.Repo)
      #=> true

      # Get current primary node
      EctoLiteFS.get_primary(MyApp.Repo)
      #=> {:ok, :node1@host}

      # Manually set primary (usually not needed)
      EctoLiteFS.set_primary(MyApp.Repo, node())
      #=> :ok

      # Invalidate cache (force refresh from DB)
      EctoLiteFS.invalidate_cache(MyApp.Repo)
      #=> :ok
  """

  alias EctoLiteFS.Tracker

  @doc """
  Returns the Tracker pid for the given repo module.

  Raises `ArgumentError` if:
  - The EctoLiteFS supervisor for this repo is not running
  - No Tracker is registered for the given Repo

  ## Examples

      iex> EctoLiteFS.get_tracker!(MyApp.Repo)
      #PID<0.123.0>

      iex> EctoLiteFS.get_tracker!(UnregisteredRepo)
      ** (ArgumentError) no EctoLiteFS tracker registered for UnregisteredRepo

  """
  @spec get_tracker!(module()) :: pid()
  def get_tracker!(repo) when is_atom(repo) do
    case Process.whereis(Tracker.process_name(repo)) do
      nil ->
        raise ArgumentError,
              "no EctoLiteFS tracker registered for #{inspect(repo)}"

      pid ->
        pid
    end
  end

  @doc """
  Checks if the Tracker for the given repo has completed initialization.

  Returns `true` if the tracker is ready, `false` otherwise.
  """
  @spec tracker_ready?(module()) :: boolean()
  def tracker_ready?(repo) when is_atom(repo) do
    Tracker.ready?(repo)
  end

  @doc """
  Returns `true` if the current node is the primary for the given repo.

  Delegates to `EctoLiteFS.Tracker.is_primary?/1`.
  """
  @spec is_primary?(module()) :: boolean()
  defdelegate is_primary?(repo), to: Tracker

  @doc """
  Gets the current primary node from cache, refreshing from DB if stale.

  Delegates to `EctoLiteFS.Tracker.get_primary/1`.

  Returns `{:ok, node}` if a primary is known, `{:ok, nil}` if no primary
  has been recorded, or `{:error, :not_ready}` if tracker isn't initialized.
  """
  @spec get_primary(module()) :: {:ok, node() | nil} | {:error, term()}
  defdelegate get_primary(repo), to: Tracker

  @doc """
  Sets the current node as primary, writing to DB and updating cache.

  Delegates to `EctoLiteFS.Tracker.set_primary/2`.

  Returns `:ok` on success, `{:error, reason}` on failure.
  """
  @spec set_primary(module(), node()) :: :ok | {:error, term()}
  defdelegate set_primary(repo, node), to: Tracker

  @doc """
  Notifies the Tracker that this node is now a replica.

  Delegates to `EctoLiteFS.Tracker.set_replica/1`.

  Returns `:ok` on success, `{:error, reason}` on failure.
  """
  @spec set_replica(module()) :: :ok | {:error, term()}
  defdelegate set_replica(repo), to: Tracker

  @doc """
  Invalidates the cache, clearing any cached primary info.

  Delegates to `EctoLiteFS.Tracker.invalidate_cache/1`.
  """
  @spec invalidate_cache(module()) :: :ok
  defdelegate invalidate_cache(repo), to: Tracker

  @doc """
  Returns the configured erpc_timeout for the given repo.

  Delegates to `EctoLiteFS.Tracker.get_erpc_timeout/1`.
  """
  @spec get_erpc_timeout(module()) :: pos_integer()
  defdelegate get_erpc_timeout(repo), to: Tracker
end
