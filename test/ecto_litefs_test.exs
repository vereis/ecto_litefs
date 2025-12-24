defmodule EctoLiteFSTest do
  use ExUnit.Case, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias EctoLiteFS.Test.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok
  end

  describe "project setup" do
    test "repo can execute basic queries" do
      assert {:ok, %{rows: [[1]]}} = Repo.query("SELECT 1")
    end

    test "repo is using SQLite adapter" do
      assert Repo.__adapter__() == Ecto.Adapters.SQLite3
    end
  end
end
