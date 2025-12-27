defmodule EctoLiteFS.MiddlewareTest do
  use EctoLiteFS.Case, async: false

  alias EctoLiteFS.Middleware
  alias EctoLiteFS.Test.Repo, as: TestRepo
  alias EctoMiddleware.Resolution

  describe "process/2" do
    test "executes read operations locally without checking primary status" do
      resolution = %Resolution{
        repo: TestRepo,
        action: :all,
        args: [],
        middleware: [],
        private: %{
          __super__: fn _resource, _resolution -> {:ok, [%{id: 1}]} end
        }
      }

      result = Middleware.process(:query, resolution)
      assert result == {:ok, [%{id: 1}]}
    end

    test "executes write locally when on primary node" do
      table_name = unique_table_name("_primary_write")

      start_supervised!({EctoLiteFS.Supervisor, repo: TestRepo, primary_file: "/tmp/test", table_name: table_name})

      eventually(fn -> EctoLiteFS.tracker_ready?(TestRepo) end)

      :ok = EctoLiteFS.set_primary(TestRepo, node())

      resolution = %Resolution{
        repo: TestRepo,
        action: :insert,
        args: [],
        middleware: [],
        private: %{
          __super__: fn _resource, _resolution -> {:ok, %{id: 1}} end
        }
      }

      result = Middleware.process(:changeset, resolution)
      assert result == {:ok, %{id: 1}}
    end

    test "returns erpc error tuple when primary is unreachable" do
      {_temp_dir, primary_file} = create_temp_primary_file()
      File.write!(primary_file, "other-node")

      table_name = unique_table_name("_replica_write")

      start_supervised!(
        {EctoLiteFS.Supervisor,
         repo: TestRepo, primary_file: primary_file, table_name: table_name, poll_interval: 1_000_000}
      )

      eventually(fn -> EctoLiteFS.tracker_ready?(TestRepo) end)

      primary_node = :fake_primary@fake_host
      :ok = EctoLiteFS.set_primary(TestRepo, primary_node)

      resolution = %Resolution{
        repo: TestRepo,
        action: :update,
        args: [],
        middleware: [],
        private: %{
          __super__: fn _resource, _resolution -> {:ok, %{id: 1, updated: true}} end
        }
      }

      result = Middleware.process(:changeset, resolution)
      assert {:error, {:erpc, :noconnection, :fake_primary@fake_host}} = result
    end

    test "returns error when primary is not available" do
      {_temp_dir, primary_file} = create_temp_primary_file()
      File.write!(primary_file, "")

      table_name = unique_table_name("_no_primary")

      start_supervised!(
        {EctoLiteFS.Supervisor,
         repo: TestRepo, primary_file: primary_file, table_name: table_name, poll_interval: 1_000_000}
      )

      eventually(fn -> EctoLiteFS.tracker_ready?(TestRepo) end)

      :ok = EctoLiteFS.set_replica(TestRepo)

      resolution = %Resolution{
        repo: TestRepo,
        action: :delete,
        args: [],
        middleware: [],
        private: %{
          __super__: fn _resource, _resolution -> {:ok, %{id: 1}} end
        }
      }

      result = Middleware.process(:struct, resolution)
      assert result == {:error, :primary_unavailable}
    end

    test "detects all write operations correctly" do
      table_name = unique_table_name("_write_detect")

      start_supervised!({EctoLiteFS.Supervisor, repo: TestRepo, primary_file: "/tmp/test", table_name: table_name})

      eventually(fn -> EctoLiteFS.tracker_ready?(TestRepo) end)

      :ok = EctoLiteFS.set_primary(TestRepo, node())

      write_actions = [:insert, :insert_all, :insert_or_update, :update, :update_all, :delete, :delete_all]

      for action <- write_actions do
        resolution = %Resolution{
          repo: TestRepo,
          action: action,
          args: [],
          middleware: [],
          private: %{
            __super__: fn _resource, _resolution -> {:ok, :write_result} end
          }
        }

        result = Middleware.process(:resource, resolution)
        assert result == {:ok, :write_result}, "Action #{action} should be treated as a write"
      end
    end

    test "treats non-write operations as reads" do
      read_actions = [:all, :get, :get!, :get_by, :get_by!, :one, :one!, :reload, :reload!, :preload]

      for action <- read_actions do
        resolution = %Resolution{
          repo: TestRepo,
          action: action,
          args: [],
          middleware: [],
          private: %{
            __super__: fn _resource, _resolution -> {:ok, :read_result} end
          }
        }

        result = Middleware.process(:resource, resolution)
        assert result == {:ok, :read_result}, "Action #{action} should be treated as a read"
      end
    end
  end
end
