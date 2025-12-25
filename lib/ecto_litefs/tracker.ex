defmodule EctoLiteFS.Tracker do
  @moduledoc """
  GenServer that manages the ETS cache and database table for primary tracking.

  The Tracker is responsible for:
  - Creating and owning the ETS table for caching primary info
  - Ensuring the database table exists via `CREATE TABLE IF NOT EXISTS`
  - Registering itself in the instance's Registry for lookup by repo module
  """

  use GenServer

  alias Ecto.Adapters.SQL
  alias EctoLiteFS.Config

  require Logger

  @default_max_retries 5
  @default_base_retry_delay_ms 100

  @doc """
  Starts the Tracker GenServer.
  """
  @spec start_link(Config.t()) :: GenServer.on_start()
  def start_link(%Config{} = config) do
    name = process_name(config.name)
    GenServer.start_link(__MODULE__, config, name: name)
  end

  @doc """
  Returns the process name for a Tracker with the given instance name.
  """
  @spec process_name(atom()) :: atom()
  def process_name(name) when is_atom(name) do
    Module.concat(__MODULE__, name)
  end

  @doc """
  Returns the ETS table name for a given instance name.
  """
  @spec ets_table_name(atom()) :: atom()
  def ets_table_name(name) when is_atom(name) do
    :"ecto_litefs_#{name}"
  end

  @doc """
  Checks if the Tracker has completed initialization.
  """
  @spec ready?(atom()) :: boolean()
  def ready?(name) when is_atom(name) do
    case Process.whereis(process_name(name)) do
      nil -> false
      pid -> GenServer.call(pid, :ready?)
    end
  catch
    :exit, _ -> false
  end

  @impl GenServer
  def init(%Config{} = config) do
    state = %{
      config: config,
      ets_table: nil,
      db_ready: false
    }

    {:ok, state, {:continue, :init_db}}
  end

  @impl GenServer
  def handle_continue(:init_db, state) do
    case ensure_db_table(state.config, 0, @default_max_retries, @default_base_retry_delay_ms) do
      :ok ->
        register_for_repo!(state.config.name, state.config.repo)
        ets_table = create_ets_table(state.config.name)
        {:noreply, %{state | ets_table: ets_table, db_ready: true}}

      {:error, reason} ->
        {:stop, {:db_init_failed, reason}, state}
    end
  end

  @impl GenServer
  def handle_call(:ready?, _from, state) do
    {:reply, state.db_ready, state}
  end

  defp create_ets_table(name) do
    table_name = ets_table_name(name)
    :ets.new(table_name, [:named_table, :public, :set, read_concurrency: true])
    table_name
  end

  defp register_for_repo!(instance_name, repo) do
    registry = EctoLiteFS.registry_name(instance_name)

    case Registry.register(registry, repo, nil) do
      {:ok, _} ->
        :ok

      {:error, {:already_registered, pid}} ->
        raise ArgumentError,
              "EctoLiteFS tracker already registered for #{inspect(repo)} at #{inspect(pid)}"
    end
  end

  defp ensure_db_table(%Config{} = config, retry_count, max_retries, base_delay) when retry_count < max_retries do
    sql = """
    CREATE TABLE IF NOT EXISTS #{config.table_name} (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      node_name TEXT NOT NULL,
      updated_at INTEGER NOT NULL
    )
    """

    case execute_sql(config.repo, sql) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "EctoLiteFS.Tracker[#{config.name}]: DB init failed (attempt #{retry_count + 1}/#{max_retries}), retrying: #{inspect(reason)}"
        )

        delay = trunc(base_delay * :math.pow(2, retry_count))
        Process.sleep(delay)
        ensure_db_table(config, retry_count + 1, max_retries, base_delay)
    end
  end

  defp ensure_db_table(%Config{} = config, _retry_count, max_retries, _base_delay) do
    Logger.error("EctoLiteFS.Tracker[#{config.name}]: DB init failed after #{max_retries} retries")
    {:error, :max_retries_exceeded}
  end

  defp execute_sql(repo, sql) do
    SQL.query(repo, sql, [])
  rescue
    e in DBConnection.ConnectionError -> {:error, e}
    e in Ecto.QueryError -> {:error, e}
  end
end
