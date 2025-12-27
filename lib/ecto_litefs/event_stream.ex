defmodule EctoLiteFS.EventStream do
  @moduledoc """
  GenServer that connects to the LiteFS HTTP event stream.

  Receives real-time notifications of primary status changes from LiteFS.
  Events are newline-delimited JSON with the following types:
  - `init` - sent on connection, contains `data.isPrimary` and `data.hostname`
  - `primaryChange` - sent when primary status changes, same structure
  - `tx` - transaction events (ignored for now)

  The connection will timeout after 30 seconds if unable to reach the LiteFS
  endpoint. If the stream ends or errors, the GenServer stops and the 
  supervisor restarts it.
  """

  use GenServer

  alias EctoLiteFS.Config
  alias EctoLiteFS.Tracker

  require Logger

  @doc """
  Starts the EventStream GenServer.
  """
  @spec start_link(Config.t()) :: GenServer.on_start()
  def start_link(%Config{} = config) do
    GenServer.start_link(__MODULE__, config, name: process_name(config.repo))
  end

  @doc """
  Returns the process name for an EventStream with the given repo module.
  """
  @spec process_name(module()) :: atom()
  def process_name(repo) when is_atom(repo) do
    Module.concat(__MODULE__, repo)
  end

  @impl GenServer
  def init(%Config{} = config) do
    state = %{
      config: config,
      buffer: ""
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, state) do
    url = state.config.event_stream_url
    Logger.debug("EctoLiteFS.EventStream[#{inspect(state.config.repo)}]: connecting to #{url}")

    parent = self()

    # Spawn a linked process to handle the HTTP stream. This keeps the GenServer
    # free to process {:chunk, ...} messages in real-time rather than blocking.
    spawn_link(fn ->
      into_fun = fn {:data, chunk}, acc ->
        send(parent, {:chunk, chunk})
        {:cont, acc}
      end

      result =
        Req.get(url,
          into: into_fun,
          receive_timeout: :infinity,
          connect_options: [timeout: 30_000]
        )

      send(parent, {:stream_ended, result})
    end)

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:chunk, chunk}, state) do
    parts = String.split(state.buffer <> chunk, "\n")
    {lines, [remaining]} = Enum.split(parts, -1)

    Enum.each(lines, fn line ->
      if line != "" do
        handle_line(state.config.repo, line)
      end
    end)

    {:noreply, %{state | buffer: remaining}}
  end

  @impl GenServer
  def handle_info({:stream_ended, result}, state) do
    case result do
      {:ok, %Req.Response{status: 200}} ->
        Logger.debug("EctoLiteFS.EventStream[#{inspect(state.config.repo)}]: stream ended normally")
        {:stop, :normal, state}

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("EctoLiteFS.EventStream[#{inspect(state.config.repo)}]: unexpected status #{status}")
        {:stop, {:error, {:unexpected_status, status}}, state}

      {:error, reason} ->
        Logger.warning("EctoLiteFS.EventStream[#{inspect(state.config.repo)}]: connection failed: #{inspect(reason)}")
        {:stop, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_info(msg, state) do
    Logger.warning("EctoLiteFS.EventStream[#{inspect(state.config.repo)}]: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp handle_line(repo, line) do
    case Jason.decode(line) do
      {:ok, event} ->
        handle_event(repo, event)

      {:error, reason} ->
        Logger.warning(
          "EctoLiteFS.EventStream[#{inspect(repo)}]: failed to parse JSON: #{inspect(reason)}, line: #{inspect(line)}"
        )
    end
  end

  defp handle_event(repo, %{"type" => "init", "data" => %{"isPrimary" => is_primary} = data}) do
    hostname = Map.get(data, "hostname", "")
    handle_primary_status_change(repo, is_primary, "init", hostname)
  end

  defp handle_event(repo, %{"type" => "primaryChange", "data" => %{"isPrimary" => is_primary} = data}) do
    hostname = Map.get(data, "hostname", "")
    handle_primary_status_change(repo, is_primary, "primaryChange", hostname)
  end

  defp handle_event(repo, %{"type" => "tx"}) do
    Logger.debug("EctoLiteFS.EventStream[#{inspect(repo)}]: tx event (ignored)")
  end

  defp handle_event(repo, event) do
    Logger.debug("EctoLiteFS.EventStream[#{inspect(repo)}]: unknown event type: #{inspect(event)}")
  end

  defp handle_primary_status_change(repo, true = _is_primary, event_type, hostname) do
    Logger.debug("EctoLiteFS.EventStream[#{inspect(repo)}]: #{event_type} event - primary, hostname=#{hostname}")
    notify_tracker(repo, {:set_primary, Node.self()})
  end

  defp handle_primary_status_change(repo, false = _is_primary, event_type, hostname) do
    Logger.debug("EctoLiteFS.EventStream[#{inspect(repo)}]: #{event_type} event - replica, hostname=#{hostname}")
    notify_tracker(repo, :set_replica)
  end

  defp notify_tracker(repo, {:set_primary, node}) do
    if Tracker.ready?(repo) do
      case Tracker.set_primary(repo, node) do
        :ok ->
          true

        {:error, reason} ->
          Logger.debug("EctoLiteFS.EventStream[#{inspect(repo)}]: set_primary failed: #{inspect(reason)}")
          false
      end
    else
      Logger.debug("EctoLiteFS.EventStream[#{inspect(repo)}]: tracker not ready, skipping set_primary")
      false
    end
  catch
    :exit, reason ->
      Logger.debug("EctoLiteFS.EventStream[#{inspect(repo)}]: tracker unavailable: #{inspect(reason)}")
      false
  end

  defp notify_tracker(repo, :set_replica) do
    if Tracker.ready?(repo) do
      case Tracker.set_replica(repo) do
        :ok ->
          true

        {:error, reason} ->
          Logger.debug("EctoLiteFS.EventStream[#{inspect(repo)}]: set_replica failed: #{inspect(reason)}")
          false
      end
    else
      Logger.debug("EctoLiteFS.EventStream[#{inspect(repo)}]: tracker not ready, skipping set_replica")
      false
    end
  catch
    :exit, reason ->
      Logger.debug("EctoLiteFS.EventStream[#{inspect(repo)}]: tracker unavailable: #{inspect(reason)}")
      false
  end
end
