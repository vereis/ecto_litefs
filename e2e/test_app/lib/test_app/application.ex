defmodule TestApp.Application do
  @moduledoc false
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    # Start distributed Erlang if NODE_NAME is set
    setup_distribution()

    litefs_config = Application.get_env(:test_app, :litefs)

    children = [
      TestApp.Repo,
      {EctoLiteFS.Supervisor,
       repo: TestApp.Repo, primary_file: litefs_config[:primary_file], event_stream_url: litefs_config[:event_stream_url]},
      {Plug.Cowboy, scheme: :http, plug: TestApp.Router, options: [port: 4000]},
      # Start cluster connector after EctoLiteFS is ready
      {Task, fn -> connect_to_cluster() end}
    ]

    opts = [strategy: :one_for_one, name: TestApp.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # Run migrations on startup (only on primary)
        run_migrations()
        {:ok, pid}

      error ->
        error
    end
  end

  defp setup_distribution do
    case System.get_env("NODE_NAME") do
      nil ->
        Logger.info("NODE_NAME not set, running without distribution")

      node_name ->
        node = String.to_atom(node_name)
        cookie = "ERLANG_COOKIE" |> System.get_env("ecto_litefs_e2e") |> String.to_atom()

        case Node.start(node, :shortnames) do
          {:ok, _pid} ->
            Node.set_cookie(cookie)
            Logger.info("Started distributed node: #{node}")

          {:error, reason} ->
            Logger.warning("Failed to start distribution: #{inspect(reason)}")
        end
    end
  end

  defp connect_to_cluster do
    # Wait a bit for services to start
    Process.sleep(2000)

    case System.get_env("PRIMARY_NODE") do
      nil ->
        Logger.info("PRIMARY_NODE not set, not connecting to cluster")

      primary_node_name ->
        primary_node = String.to_atom(primary_node_name)

        if Node.self() != primary_node do
          Logger.info("Attempting to connect to primary: #{primary_node}")

          # Retry connection a few times
          connect_with_retry(primary_node, 10)
        end
    end
  end

  defp connect_with_retry(_node, 0) do
    Logger.warning("Failed to connect to primary after retries")
  end

  defp connect_with_retry(node, retries) do
    case Node.connect(node) do
      true ->
        Logger.info("Connected to primary node: #{node}")

      false ->
        Logger.info("Connection to #{node} failed, retrying... (#{retries - 1} left)")
        Process.sleep(1000)
        connect_with_retry(node, retries - 1)

      :ignored ->
        Logger.info("Node not alive, cannot connect")
    end
  end

  defp run_migrations do
    # Only run migrations if we're the primary (no .primary file exists)
    primary_file = Application.get_env(:test_app, :litefs)[:primary_file]

    if File.exists?(primary_file) do
      Logger.info("Skipping migrations (this is a replica)")
    else
      Logger.info("Running migrations (this is the primary)")

      TestApp.Repo.query!("""
      CREATE TABLE IF NOT EXISTS items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        created_at TEXT DEFAULT CURRENT_TIMESTAMP
      )
      """)
    end
  end
end
