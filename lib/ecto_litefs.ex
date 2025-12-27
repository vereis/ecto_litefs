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
          repo: MyApp.Repo,
          primary_file: "/litefs/.primary",
          poll_interval: 30_000,
          event_stream_url: "http://localhost:20202/events"
        }
      ]

  ## Configuration Options

  * `:repo` - Required. The Ecto Repo module to track (also serves as the unique identifier).
  * `:primary_file` - Path to LiteFS `.primary` file. Default: `"/litefs/.primary"`
  * `:poll_interval` - Filesystem poll interval in ms. Default: `30_000`
  * `:event_stream_url` - LiteFS HTTP events endpoint. Default: `"http://localhost:20202/events"`
  * `:table_name` - Database table for primary tracking. Default: `"_ecto_litefs_primary"`
  * `:cache_ttl` - Cache TTL in ms. Default: `5_000`
  * `:erpc_timeout` - Timeout for `:erpc` calls when forwarding writes to primary. Default: `15_000`
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
