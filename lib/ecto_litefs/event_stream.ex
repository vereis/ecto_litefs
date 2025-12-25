defmodule EctoLiteFS.EventStream do
  @moduledoc """
  GenServer that connects to the LiteFS HTTP event stream.

  Receives real-time notifications of primary status changes from LiteFS.
  Events are newline-delimited JSON with the following types:
  - `init` - sent on connection, contains `data.isPrimary` and `data.hostname`
  - `primaryChange` - sent when primary status changes, same structure
  - `tx` - transaction events (ignored for now)

  If the stream ends or errors, the GenServer stops and the supervisor restarts it.
  """

  use GenServer

  alias EctoLiteFS.Config

  require Logger

  @doc """
  Starts the EventStream GenServer.
  """
  @spec start_link(Config.t()) :: GenServer.on_start()
  def start_link(%Config{} = config) do
    GenServer.start_link(__MODULE__, config, name: process_name(config.name))
  end

  @doc """
  Returns the process name for an EventStream with the given instance name.
  """
  @spec process_name(atom()) :: atom()
  def process_name(name) when is_atom(name) do
    Module.concat(__MODULE__, name)
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
    Logger.debug("EctoLiteFS.EventStream[#{state.config.name}]: connecting to #{url}")

    parent = self()

    # Spawn a linked process to handle the HTTP stream. This keeps the GenServer
    # free to process {:chunk, ...} messages in real-time rather than blocking.
    spawn_link(fn ->
      into_fun = fn {:data, chunk}, acc ->
        send(parent, {:chunk, chunk})
        {:cont, acc}
      end

      result = Req.get(url, into: into_fun, receive_timeout: :infinity)
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
        handle_line(state.config.name, line)
      end
    end)

    {:noreply, %{state | buffer: remaining}}
  end

  @impl GenServer
  def handle_info({:stream_ended, result}, state) do
    case result do
      {:ok, %Req.Response{status: 200}} ->
        Logger.debug("EctoLiteFS.EventStream[#{state.config.name}]: stream ended normally")
        {:stop, :normal, state}

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("EctoLiteFS.EventStream[#{state.config.name}]: unexpected status #{status}")
        {:stop, {:error, {:unexpected_status, status}}, state}

      {:error, reason} ->
        Logger.warning("EctoLiteFS.EventStream[#{state.config.name}]: connection failed: #{inspect(reason)}")
        {:stop, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_info(msg, state) do
    Logger.warning("EctoLiteFS.EventStream[#{state.config.name}]: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp handle_line(name, line) do
    case Jason.decode(line) do
      {:ok, event} ->
        handle_event(name, event)

      {:error, reason} ->
        Logger.warning(
          "EctoLiteFS.EventStream[#{name}]: failed to parse JSON: #{inspect(reason)}, line: #{inspect(line)}"
        )
    end
  end

  defp handle_event(name, %{"type" => "init", "data" => %{"isPrimary" => is_primary} = data}) do
    status = if is_primary, do: "primary", else: "replica"
    hostname = Map.get(data, "hostname", "")
    Logger.debug("EctoLiteFS.EventStream[#{name}]: init event - #{status}, hostname=#{hostname}")
  end

  defp handle_event(name, %{"type" => "primaryChange", "data" => %{"isPrimary" => is_primary} = data}) do
    status = if is_primary, do: "primary", else: "replica"
    hostname = Map.get(data, "hostname", "")
    Logger.debug("EctoLiteFS.EventStream[#{name}]: primaryChange event - #{status}, hostname=#{hostname}")
  end

  defp handle_event(name, %{"type" => "tx"}) do
    Logger.debug("EctoLiteFS.EventStream[#{name}]: tx event (ignored)")
  end

  defp handle_event(name, event) do
    Logger.debug("EctoLiteFS.EventStream[#{name}]: unknown event type: #{inspect(event)}")
  end
end
