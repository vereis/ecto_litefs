defmodule EctoLiteFS.Poller do
  @moduledoc """
  GenServer that polls the filesystem to detect LiteFS primary status.

  Checks for the presence of the `.primary` file at configured intervals.
  When the file is absent, this node is the primary. When present, this node
  is a replica.
  """

  use GenServer

  alias EctoLiteFS.Config

  require Logger

  # Small delay before first poll to avoid thundering herd when supervision tree starts
  @initial_poll_delay_ms 100

  @doc """
  Starts the Poller GenServer.
  """
  @spec start_link(Config.t()) :: GenServer.on_start()
  def start_link(%Config{} = config) do
    name = process_name(config.name)
    GenServer.start_link(__MODULE__, config, name: name)
  end

  @doc """
  Returns the process name for a Poller with the given instance name.
  """
  @spec process_name(atom()) :: atom()
  def process_name(name) when is_atom(name) do
    Module.concat(__MODULE__, name)
  end

  @impl GenServer
  def init(%Config{} = config) do
    schedule_poll(@initial_poll_delay_ms)
    {:ok, config}
  end

  @impl GenServer
  def handle_info(:poll, %Config{} = config) do
    is_primary = check_primary_status(config.primary_file)

    Logger.debug("EctoLiteFS.Poller[#{config.name}]: #{(is_primary && "primary") || "replica"}")

    schedule_poll(config.poll_interval)
    {:noreply, config}
  end

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll, interval)
  end

  defp check_primary_status(primary_file) do
    not File.exists?(primary_file)
  end
end
