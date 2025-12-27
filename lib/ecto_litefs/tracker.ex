defmodule EctoLiteFS.Tracker do
  @moduledoc """
  GenServer that manages the ETS cache and database table for primary tracking.

  The Tracker is responsible for:
  - Creating and owning the ETS table for caching primary info
  - Ensuring the database table exists via `CREATE TABLE IF NOT EXISTS`
  - Registering itself with a repo-based process name for direct lookup
  - Providing public API for reading/writing primary status

  ## Initialization

  The Tracker uses non-blocking initialization with automatic retries. If the
  database is not immediately available, it will retry with exponential backoff
  instead of blocking the GenServer process with `Process.sleep/1`.

  During initialization, all GenServer calls (except `:ready?`) will return
  `{:error, :not_ready}` to prevent crashes or timeouts.

  ## Atom Safety

  To prevent atom table exhaustion attacks, the Tracker only accepts node names
  that are present in the connected cluster (`[Node.self() | Node.list()]`).
  Node names from the database are cross-referenced against this list, and
  disconnected nodes are rejected with an error log.

  ## Cache Refresh

  The Tracker implements single-flight cache refresh with a configurable grace
  period (`:refresh_grace_period`). If multiple processes request a refresh
  within the grace period, the first refresh wins and subsequent requests
  return the cached value without hitting the database.
  """

  use GenServer

  alias Ecto.Adapters.SQL
  alias EctoLiteFS.Config

  require Logger

  @default_max_retries 5

  @ets_key :primary_info

  @doc """
  Starts the Tracker GenServer.
  """
  @spec start_link(Config.t()) :: GenServer.on_start()
  def start_link(%Config{} = config) do
    GenServer.start_link(__MODULE__, config, name: process_name(config.repo))
  end

  @doc """
  Returns the process name for a Tracker with the given repo module.
  """
  @spec process_name(module()) :: atom()
  def process_name(repo) when is_atom(repo) do
    Module.concat(__MODULE__, repo)
  end

  @doc """
  Returns the ETS table name for a given repo module.
  """
  @spec ets_table_name(module()) :: atom()
  def ets_table_name(repo) when is_atom(repo) do
    Module.concat([EctoLiteFS, repo, ETS])
  end

  @doc """
  Checks if the Tracker has completed initialization.
  """
  @spec ready?(module()) :: boolean()
  def ready?(repo) when is_atom(repo) do
    case Process.whereis(process_name(repo)) do
      nil -> false
      pid -> GenServer.call(pid, :ready?)
    end
  catch
    :exit, _reason -> false
  end

  @doc """
  Sets the current node as primary, writing to DB and updating cache.

  Returns `:ok` on success, `{:error, reason}` on failure.
  When running on a replica, the DB write will fail (LiteFS rejects writes)
  and the cache will NOT be updated.
  """
  @spec set_primary(module(), node()) :: :ok | {:error, term()}
  def set_primary(repo, node) when is_atom(repo) and is_atom(node) do
    GenServer.call(process_name(repo), {:set_primary, node})
  end

  @doc """
  Notifies the Tracker that this node is now a replica.

  Refreshes the cache from the database to get the new primary's info.
  Returns `:ok` on success, `{:error, reason}` on failure.
  """
  @spec set_replica(module()) :: :ok | {:error, term()}
  def set_replica(repo) when is_atom(repo) do
    GenServer.call(process_name(repo), :set_replica)
  end

  @doc """
  Gets the current primary node from cache, refreshing from DB if stale.

  Returns `{:ok, node}` if a primary is known, `{:ok, nil}` if no primary
  has been recorded, or `{:error, :not_ready}` if tracker isn't initialized.

  Reads directly from ETS when cache is fresh, falling back to GenServer
  call to refresh from DB when stale or empty.

  ## Options

  * `:force` - When `true`, bypasses cache and forces a DB refresh. Default: `false`

  ## Examples

      iex> EctoLiteFS.Tracker.get_primary(MyApp.Repo)
      {:ok, :node1@host}

      iex> EctoLiteFS.Tracker.get_primary(MyApp.Repo, force: true)
      {:ok, :node1@host}
  """
  @spec get_primary(module(), keyword()) :: {:ok, node() | nil} | {:error, term()}
  def get_primary(repo, opts \\ []) when is_atom(repo) do
    force? = Keyword.get(opts, :force, false)

    if force? do
      GenServer.call(process_name(repo), :force_refresh_cache)
    else
      get_primary_from_cache(repo)
    end
  rescue
    ArgumentError -> {:error, :not_ready}
  catch
    :exit, _reason -> {:error, :not_ready}
  end

  defp get_primary_from_cache(repo) do
    case :ets.lookup(ets_table_name(repo), @ets_key) do
      [{@ets_key, node, cached_at, ttl}] ->
        now = System.monotonic_time(:millisecond)
        cache_fresh? = now - cached_at < ttl

        if cache_fresh? do
          {:ok, node}
        else
          GenServer.call(process_name(repo), :refresh_cache)
        end

      [] ->
        GenServer.call(process_name(repo), :refresh_cache)
    end
  end

  @doc """
  Checks if the current node is the primary.

  Returns `true` if this node is the recorded primary, `false` otherwise.
  """
  @spec is_primary?(module()) :: boolean()
  def is_primary?(repo) when is_atom(repo) do
    case get_primary(repo) do
      {:ok, primary} -> primary == Node.self()
      {:error, _reason} -> false
    end
  end

  @doc """
  Invalidates the cache, clearing any cached primary info.
  """
  @spec invalidate_cache(module()) :: :ok
  def invalidate_cache(repo) when is_atom(repo) do
    GenServer.call(process_name(repo), :invalidate_cache)
  end

  @impl GenServer
  def init(%Config{} = config) do
    {:ok,
     %{
       config: config,
       ets_table: nil,
       db_ready: false,
       retry_count: 0,
       last_refresh_at: nil
     }, {:continue, :init_db}}
  end

  @impl GenServer
  def handle_continue(:init_db, state) do
    case try_init_db(state.config) do
      :ok ->
        ets_table = :ets.new(ets_table_name(state.config.repo), [:named_table, :public, :set, read_concurrency: true])
        {:noreply, %{state | ets_table: ets_table, db_ready: true}}

      {:error, reason} ->
        if state.retry_count < @default_max_retries do
          delay = EctoLiteFS.Utils.backoff_delay(state.retry_count)

          Logger.warning(
            "EctoLiteFS.Tracker[#{inspect(state.config.repo)}]: DB init failed, retrying in #{delay}ms: #{inspect(reason)}"
          )

          Process.send_after(self(), :retry_init_db, delay)
          {:noreply, %{state | retry_count: state.retry_count + 1}}
        else
          Logger.error(
            "EctoLiteFS.Tracker[#{inspect(state.config.repo)}]: DB init failed after #{@default_max_retries} retries"
          )

          {:stop, {:db_init_failed, reason}, state}
        end
    end
  end

  @impl GenServer
  def handle_call(:ready?, _from, state) do
    {:reply, state.db_ready, state}
  end

  def handle_call(_request, _from, %{db_ready: false} = state) do
    {:reply, {:error, :not_ready}, state}
  end

  def handle_call({:set_primary, node}, _from, state) do
    node_name = Atom.to_string(node)
    sql = "INSERT OR REPLACE INTO #{state.config.table_name} (id, node_name, updated_at) VALUES (1, ?, ?)"

    case SQL.query(state.config.repo, sql, [node_name, System.system_time(:second)]) do
      {:ok, _result} ->
        Logger.debug("EctoLiteFS.Tracker[#{inspect(state.config.repo)}]: wrote primary=#{node_name}")
        :ets.insert(state.ets_table, {@ets_key, node, System.monotonic_time(:millisecond), state.config.cache_ttl})
        {:reply, :ok, state}

      {:error, reason} ->
        Logger.debug(
          "EctoLiteFS.Tracker[#{inspect(state.config.repo)}]: write rejected (expected on replica): #{inspect(reason)}"
        )

        {:reply, {:error, reason}, state}
    end
  rescue
    e in [DBConnection.ConnectionError, Ecto.QueryError] ->
      Logger.debug("EctoLiteFS.Tracker[#{inspect(state.config.repo)}]: write failed: #{inspect(e)}")
      {:reply, {:error, e}, state}
  end

  def handle_call(:set_replica, _from, state) do
    {:reply, refresh_cache_from_db(state), state}
  end

  def handle_call(:refresh_cache, _from, state) do
    now = System.monotonic_time(:millisecond)
    grace_period = state.config.refresh_grace_period

    within_grace_period? = state.last_refresh_at && now - state.last_refresh_at < grace_period

    if within_grace_period? do
      result = get_cached_primary(state)
      {:reply, result, state}
    else
      do_refresh_cache(state, now)
    end
  end

  def handle_call(:force_refresh_cache, _from, state) do
    now = System.monotonic_time(:millisecond)
    do_refresh_cache(state, now)
  end

  def handle_call(:invalidate_cache, _from, state) do
    :ets.delete(state.ets_table, @ets_key)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info(:retry_init_db, state) do
    {:noreply, state, {:continue, :init_db}}
  end

  defp try_init_db(config) do
    sql = """
    CREATE TABLE IF NOT EXISTS #{config.table_name} (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      node_name TEXT NOT NULL,
      updated_at INTEGER NOT NULL
    )
    """

    case SQL.query(config.repo, sql, []) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    e in [DBConnection.ConnectionError, Ecto.QueryError] -> {:error, e}
  end

  defp get_cached_primary(state) do
    case :ets.lookup(state.ets_table, @ets_key) do
      [{@ets_key, node, _cached_at, _ttl}] -> {:ok, node}
      [] -> {:ok, nil}
    end
  end

  defp do_refresh_cache(state, now) do
    case refresh_cache_from_db(state) do
      :ok ->
        result = get_cached_primary(state)
        {:reply, result, %{state | last_refresh_at: now}}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  defp refresh_cache_from_db(state) do
    sql = "SELECT node_name FROM #{state.config.table_name} WHERE id = 1"

    case SQL.query(state.config.repo, sql, []) do
      {:ok, %{rows: [[node_name]]}} ->
        connected_nodes = Map.new([Node.self() | Node.list()], &{Atom.to_string(&1), &1})

        case Map.get(connected_nodes, node_name) do
          nil ->
            Logger.error(
              "EctoLiteFS.Tracker[#{inspect(state.config.repo)}]: primary node #{inspect(node_name)} is not connected to cluster"
            )

            :ets.delete(state.ets_table, @ets_key)
            :ok

          node ->
            :ets.insert(
              state.ets_table,
              {@ets_key, node, System.monotonic_time(:millisecond), state.config.cache_ttl}
            )

            :ok
        end

      {:ok, %{rows: []}} ->
        :ets.delete(state.ets_table, @ets_key)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e in [DBConnection.ConnectionError, Ecto.QueryError] -> {:error, e}
  end
end
