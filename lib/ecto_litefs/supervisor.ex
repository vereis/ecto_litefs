defmodule EctoLiteFS.Supervisor do
  @moduledoc """
  Supervisor for EctoLiteFS processes.

  Add this supervisor to your application's supervision tree, after your Repo:

      children = [
        MyApp.Repo,
        {EctoLiteFS.Supervisor,
          name: :my_litefs,
          repo: MyApp.Repo
        }
      ]

  ## Options

  See `EctoLiteFS.Config` for all available options.
  """

  use Supervisor

  alias EctoLiteFS.Config
  alias EctoLiteFS.Poller
  alias EctoLiteFS.Tracker

  @doc """
  Starts the EctoLiteFS supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) when is_list(opts) do
    config = Config.new!(opts)
    Supervisor.start_link(__MODULE__, config, name: supervisor_name(config.name))
  end

  @doc """
  Returns the supervisor name for a given instance name.
  """
  @spec supervisor_name(atom()) :: atom()
  def supervisor_name(name) when is_atom(name) do
    Module.concat(__MODULE__, name)
  end

  @impl Supervisor
  def init(%Config{} = config) do
    children = [
      {Registry, keys: :unique, name: EctoLiteFS.registry_name(config.name)},
      {Tracker, config},
      {Poller, config}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
