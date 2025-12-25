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

  alias EctoLiteFS.Tracker

  @doc """
  Returns the registry name for a given instance name.
  """
  @spec registry_name(atom()) :: atom()
  def registry_name(name) when is_atom(name) do
    Module.concat([__MODULE__, name, Registry])
  end

  @doc """
  Returns the Tracker pid for the given instance name and repo module.

  Raises `ArgumentError` if no Tracker is registered for the given Repo.

  ## Examples

      iex> EctoLiteFS.get_tracker!(:my_litefs, MyApp.Repo)
      #PID<0.123.0>

      iex> EctoLiteFS.get_tracker!(:unknown, MyApp.Repo)
      ** (ArgumentError) EctoLiteFS instance :unknown is not running

  """
  @spec get_tracker!(atom(), module()) :: pid()
  def get_tracker!(instance_name, repo) when is_atom(instance_name) and is_atom(repo) do
    registry = registry_name(instance_name)

    case Process.whereis(registry) do
      nil ->
        raise ArgumentError,
              "EctoLiteFS instance #{inspect(instance_name)} is not running. " <>
                "Ensure EctoLiteFS.Supervisor is started with name: #{inspect(instance_name)}"

      _pid ->
        case Registry.lookup(registry, repo) do
          [{pid, _value}] ->
            pid

          [] ->
            raise ArgumentError,
                  "no EctoLiteFS tracker registered for #{inspect(repo)} in instance #{inspect(instance_name)}"
        end
    end
  end

  @doc """
  Checks if the Tracker for the given instance has completed initialization.

  Returns `true` if the tracker is ready, `false` otherwise.
  """
  @spec tracker_ready?(atom()) :: boolean()
  def tracker_ready?(instance_name) when is_atom(instance_name) do
    Tracker.ready?(instance_name)
  end
end
