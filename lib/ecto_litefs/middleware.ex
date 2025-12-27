defmodule EctoLiteFS.Middleware do
  @moduledoc """
  EctoMiddleware that automatically forwards write operations to the primary node
  in a LiteFS cluster.

  ## Usage

  Add this middleware to your Repo's middleware pipeline. The middleware automatically
  detects write operations and forwards them to the primary node when running on a replica.

      defmodule MyApp.Repo do
        use Ecto.Repo, otp_app: :my_app
        use EctoMiddleware.Repo

        @impl EctoMiddleware.Repo
        def middleware(_resource, _action), do: [EctoLiteFS.Middleware]
      end

  The middleware uses the repo from the resolution to find the associated EctoLiteFS
  supervisor - no additional configuration is needed beyond starting the supervisor.

  For more control over which operations use the middleware, see the
  [EctoMiddleware documentation](https://hexdocs.pm/ecto_middleware) for guards like
  `is_write/2`.

  ## Limitations

  - **Transactions:** Write forwarding within `Repo.transaction/2` is not currently
    supported. Transactions must execute entirely on the primary node.

  ## Telemetry

  The middleware emits telemetry events for observability:

  - `[:ecto_litefs, :forward, :start]` - Write forwarding initiated
  - `[:ecto_litefs, :forward, :stop]` - Forwarding completed successfully
  - `[:ecto_litefs, :forward, :exception]` - Forwarding failed

  All events include metadata: `%{repo: repo, action: action, primary_node: node}`

  ## Development & Test Mode

  When `EctoLiteFS.Supervisor` is not started (e.g., in dev/test), the middleware
  automatically passes through to local execution. This means you can add the
  middleware to your Repo and it will "just work" in all environments:

  - **Production (with LiteFS):** Forwards writes to primary node
  - **Development/Test (no LiteFS):** Executes writes locally

  A debug log is emitted when passing through, so you can verify your production
  setup is correctly configured.

  ## Error Handling

  - `{:error, :primary_unavailable}` - No primary node is known (cluster may be initializing)
  - `{:error, {:erpc, :timeout, node}}` - RPC call timed out (note: the write may still complete on the primary)
  - `{:error, {:erpc, :noconnection, node}}` - Primary node is unreachable

  > #### Timeout Warning {: .warning}
  >
  > A timeout error does **not** mean the write failed. The primary node may have
  > completed the write before the timeout occurred. Design your application to
  > handle this uncertainty (e.g., idempotent writes, conflict resolution).
  """
  use EctoMiddleware

  import EctoMiddleware.Engine, only: [yield: 2]
  import EctoMiddleware.Resolution, only: [get_private: 2, put_private: 3]
  import EctoMiddleware.Utils, only: [is_write: 2]

  @impl EctoMiddleware
  def process(resource, resolution) when is_write(resource, resolution.action) do
    original_super = get_private(resolution, :__super__)
    repo = resolution.repo

    forwarding_super = fn res_resource, res ->
      case EctoLiteFS.get_primary(repo) do
        {:ok, primary_node} when primary_node == node() ->
          original_super.(res_resource, res)

        {:ok, nil} ->
          {:error, :primary_unavailable}

        {:ok, primary_node} ->
          execute_on_primary(repo, original_super, res_resource, res, primary_node)

        {:error, :not_ready} ->
          require Logger

          Logger.debug("EctoLiteFS.Middleware[#{inspect(repo)}]: not configured, passing through")
          original_super.(res_resource, res)

        {:error, reason} ->
          {:error, reason}
      end
    end

    {result, _} = yield(resource, put_private(resolution, :__super__, forwarding_super))
    result
  end

  def process(resource, resolution) do
    {result, _} = yield(resource, resolution)
    result
  end

  defp execute_on_primary(repo, original_super, resource, res, primary_node) do
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:ecto_litefs, :forward, :start],
      %{system_time: System.system_time()},
      %{repo: repo, action: res.action, primary_node: primary_node}
    )

    try do
      result =
        :erpc.call(
          primary_node,
          fn -> original_super.(resource, res) end,
          EctoLiteFS.get_erpc_timeout(repo)
        )

      :telemetry.execute(
        [:ecto_litefs, :forward, :stop],
        %{duration: System.monotonic_time() - start_time},
        %{repo: repo, action: res.action, primary_node: primary_node}
      )

      result
    catch
      :error, {:erpc, reason} ->
        :telemetry.execute(
          [:ecto_litefs, :forward, :exception],
          %{duration: System.monotonic_time() - start_time},
          %{repo: repo, action: res.action, primary_node: primary_node, reason: reason}
        )

        {:error, {:erpc, reason, primary_node}}
    end
  end
end
