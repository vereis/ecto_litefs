defmodule EctoLiteFS.Case do
  @moduledoc """
  Test case template for EctoLiteFS tests.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox
  alias EctoLiteFS.Test.Repo

  using do
    quote do
      import EctoLiteFS.Assertions
      import EctoLiteFS.Case

      alias EctoLiteFS.Config
      alias EctoLiteFS.Poller
      alias EctoLiteFS.Supervisor, as: LiteFSSupervisor
      alias EctoLiteFS.Test.Repo
      alias EctoLiteFS.Tracker
    end
  end

  setup context do
    :ok = Sandbox.checkout(Repo)

    if !context[:async] do
      Sandbox.mode(Repo, {:shared, self()})
    end

    :ok
  end

  @doc """
  Creates a temporary directory with a .primary file path.
  """
  def create_temp_primary_file do
    {:ok, temp_dir} = Briefly.create(type: :directory)
    primary_file = Path.join(temp_dir, ".primary")
    {temp_dir, primary_file}
  end

  @doc """
  Generates a unique instance name for test isolation.
  """
  def unique_name(prefix \\ :test) do
    :"#{prefix}_#{System.unique_integer([:positive, :monotonic])}"
  end

  @doc """
  Generates a unique table name for test isolation.
  """
  def unique_table_name(prefix \\ "_test_table") do
    "#{prefix}_#{System.unique_integer([:positive, :monotonic])}"
  end

  @doc """
  Checks if a database table exists.
  """
  def table_exists?(table_name) do
    result =
      Repo.query!(
        "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
        [table_name]
      )

    result.num_rows > 0
  end

  @doc """
  Drops a table if it exists.
  """
  def drop_table_if_exists(table_name) do
    Repo.query!("DROP TABLE IF EXISTS #{table_name}", [])
  end

  @doc """
  Creates the primary tracking table manually.
  """
  def create_table(table_name) do
    Repo.query!(
      """
      CREATE TABLE #{table_name} (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        node_name TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      )
      """,
      []
    )
  end
end
