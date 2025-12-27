defmodule EctoLiteFS.Supervisor do
  @moduledoc """
  Supervisor for EctoLiteFS processes.

  Add this supervisor to your application's supervision tree, after your Repo:

      children = [
        MyApp.Repo,
        {EctoLiteFS.Supervisor,
          repo: MyApp.Repo,
          primary_file: "/litefs/.primary",
          poll_interval: 30_000
        }
      ]

  ## Options

  See `EctoLiteFS.Config` for all available options.
  """

  use Supervisor

  alias EctoLiteFS.Config
  alias EctoLiteFS.EventStream
  alias EctoLiteFS.Poller
  alias EctoLiteFS.Tracker

  @doc """
  Starts the EctoLiteFS supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) when is_list(opts) do
    config = Config.new!(opts)
    Supervisor.start_link(__MODULE__, config, name: supervisor_name(config.repo))
  end

  @doc """
  Returns the supervisor name for a given repo module.
  """
  @spec supervisor_name(module()) :: atom()
  def supervisor_name(repo) when is_atom(repo) do
    Module.concat(__MODULE__, repo)
  end

  @impl Supervisor
  def init(%Config{} = config) do
    children = [
      {Tracker, config},
      {Poller, config},
      {EventStream, config}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
