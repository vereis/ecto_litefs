defmodule EctoLiteFS.Poller do
  @moduledoc """
  GenServer that polls the filesystem to detect LiteFS primary status.

  Checks for the presence of the `.primary` file at configured intervals.
  When the file is absent, this node is the primary. When present, this node
  is a replica.

  On detecting primary status, notifies the Tracker to update the database
  and cache.
  """

  use GenServer

  alias EctoLiteFS.Config
  alias EctoLiteFS.Tracker

  require Logger

  @initial_poll_delay_ms 100

  @doc """
  Starts the Poller GenServer.
  """
  @spec start_link(Config.t()) :: GenServer.on_start()
  def start_link(%Config{} = config) do
    GenServer.start_link(__MODULE__, config, name: process_name(config.repo))
  end

  @doc """
  Returns the process name for a Poller with the given repo module.
  """
  @spec process_name(module()) :: atom()
  def process_name(repo) when is_atom(repo) do
    Module.concat(__MODULE__, repo)
  end

  @impl GenServer
  def init(%Config{} = config) do
    Process.send_after(self(), :poll, @initial_poll_delay_ms)
    {:ok, %{config: config, last_status: nil}}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    is_primary = not File.exists?(state.config.primary_file)

    new_state =
      cond do
        state.last_status == is_primary ->
          state

        is_primary ->
          Logger.debug("EctoLiteFS.Poller[#{inspect(state.config.repo)}]: detected primary status")

          if notify_tracker(state.config.repo, {:set_primary, Node.self()}) do
            %{state | last_status: true}
          else
            state
          end

        true ->
          Logger.debug("EctoLiteFS.Poller[#{inspect(state.config.repo)}]: detected replica status")

          if notify_tracker(state.config.repo, :set_replica) do
            %{state | last_status: false}
          else
            state
          end
      end

    Process.send_after(self(), :poll, state.config.poll_interval)
    {:noreply, new_state}
  end

  defp notify_tracker(repo, {:set_primary, node}) do
    if Tracker.ready?(repo) do
      case Tracker.set_primary(repo, node) do
        :ok ->
          true

        {:error, reason} ->
          Logger.debug("EctoLiteFS.Poller[#{inspect(repo)}]: set_primary failed: #{inspect(reason)}")
          false
      end
    else
      Logger.debug("EctoLiteFS.Poller[#{inspect(repo)}]: tracker not ready, skipping set_primary")
      false
    end
  catch
    :exit, reason ->
      Logger.debug("EctoLiteFS.Poller[#{inspect(repo)}]: tracker unavailable: #{inspect(reason)}")
      false
  end

  defp notify_tracker(repo, :set_replica) do
    if Tracker.ready?(repo) do
      case Tracker.set_replica(repo) do
        :ok ->
          true

        {:error, reason} ->
          Logger.debug("EctoLiteFS.Poller[#{inspect(repo)}]: set_replica failed: #{inspect(reason)}")
          false
      end
    else
      Logger.debug("EctoLiteFS.Poller[#{inspect(repo)}]: tracker not ready, skipping set_replica")
      false
    end
  catch
    :exit, reason ->
      Logger.debug("EctoLiteFS.Poller[#{inspect(repo)}]: tracker unavailable: #{inspect(reason)}")
      false
  end
end
