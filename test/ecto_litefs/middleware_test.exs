defmodule EctoLiteFS.MiddlewareTest do
  use EctoLiteFS.Case, async: false

  import Mimic

  alias EctoLiteFS.Middleware
  alias EctoLiteFS.RPC
  alias EctoLiteFS.Test.Repo, as: TestRepo
  alias EctoLiteFS.Test.TelemetryHelper
  alias EctoMiddleware.Resolution

  setup :verify_on_exit!
  setup :set_mimic_global

  describe "process/2" do
    test "executes read operations locally without checking primary status" do
      reject(&RPC.call/3)

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

      reject(&RPC.call/3)

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

      reject(&RPC.call/3)

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

      reject(&RPC.call/3)

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
      reject(&RPC.call/3)

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

    test "passes through when tracker is not ready" do
      reject(&RPC.call/3)

      resolution = %Resolution{
        repo: TestRepo,
        action: :insert,
        args: [],
        middleware: [],
        private: %{
          __super__: fn _resource, _resolution -> {:ok, %{id: 1, passthrough: true}} end
        }
      }

      result = Middleware.process(:changeset, resolution)
      assert result == {:ok, %{id: 1, passthrough: true}}
    end
  end

  describe "process/2 with mocked RPC" do
    setup do
      table_name = unique_table_name("_unit_test")

      start_supervised!({EctoLiteFS.Supervisor, repo: TestRepo, primary_file: "/tmp/test", table_name: table_name})

      eventually(fn -> EctoLiteFS.tracker_ready?(TestRepo) end)

      :ok
    end

    test "forwards write to primary via RPC when on replica" do
      primary_node = :primary@host
      :ok = EctoLiteFS.set_primary(TestRepo, primary_node)

      expect(RPC, :call, fn ^primary_node, fun, _timeout -> fun.() end)

      resolution = %Resolution{
        repo: TestRepo,
        action: :update,
        args: [],
        middleware: [],
        private: %{
          __super__: fn _resource, _resolution -> {:ok, %{id: 2, forwarded: true}} end
        }
      }

      result = Middleware.process(:changeset, resolution)
      assert result == {:ok, %{id: 2, forwarded: true}}
    end

    test "returns timeout error when RPC times out" do
      primary_node = :primary@host
      :ok = EctoLiteFS.set_primary(TestRepo, primary_node)

      expect(RPC, :call, fn ^primary_node, _fun, _timeout ->
        :erlang.error({:erpc, :timeout})
      end)

      resolution = %Resolution{
        repo: TestRepo,
        action: :insert,
        args: [],
        middleware: [],
        private: %{
          __super__: fn _resource, _resolution -> {:ok, %{id: 3}} end
        }
      }

      result = Middleware.process(:changeset, resolution)
      assert {:error, {:erpc, :timeout, ^primary_node}} = result
    end

    test "returns noconnection error when RPC cannot connect" do
      primary_node = :primary@host
      :ok = EctoLiteFS.set_primary(TestRepo, primary_node)

      expect(RPC, :call, fn ^primary_node, _fun, _timeout ->
        :erlang.error({:erpc, :noconnection})
      end)

      resolution = %Resolution{
        repo: TestRepo,
        action: :delete,
        args: [],
        middleware: [],
        private: %{
          __super__: fn _resource, _resolution -> {:ok, %{id: 4}} end
        }
      }

      result = Middleware.process(:changeset, resolution)
      assert {:error, {:erpc, :noconnection, ^primary_node}} = result
    end
  end

  describe "telemetry events" do
    setup do
      table_name = unique_table_name("_telemetry")

      start_supervised!({EctoLiteFS.Supervisor, repo: TestRepo, primary_file: "/tmp/test", table_name: table_name})

      eventually(fn -> EctoLiteFS.tracker_ready?(TestRepo) end)

      primary_node = :primary@host
      :ok = EctoLiteFS.set_primary(TestRepo, primary_node)

      %{primary_node: primary_node}
    end

    test "emits start and stop events on successful forward", %{primary_node: primary_node} do
      ref =
        TelemetryHelper.attach_event_handlers(self(), [
          [:ecto_litefs, :forward, :start],
          [:ecto_litefs, :forward, :stop]
        ])

      on_exit(fn -> :telemetry.detach(ref) end)

      expect(RPC, :call, fn ^primary_node, fun, _timeout -> fun.() end)

      resolution = %Resolution{
        repo: TestRepo,
        action: :insert,
        args: [],
        middleware: [],
        private: %{
          __super__: fn _resource, _resolution -> {:ok, %{id: 1}} end
        }
      }

      Middleware.process(:changeset, resolution)

      assert_receive {[:ecto_litefs, :forward, :start], ^ref, measurements, metadata}
      assert is_integer(measurements.system_time)
      assert metadata.repo == TestRepo
      assert metadata.action == :insert
      assert metadata.primary_node == primary_node

      assert_receive {[:ecto_litefs, :forward, :stop], ^ref, measurements, metadata}
      assert is_integer(measurements.duration)
      assert measurements.duration > 0
      assert metadata.repo == TestRepo
      assert metadata.action == :insert
      assert metadata.primary_node == primary_node
    end

    test "emits exception event on RPC error", %{primary_node: primary_node} do
      ref =
        TelemetryHelper.attach_event_handlers(self(), [
          [:ecto_litefs, :forward, :start],
          [:ecto_litefs, :forward, :exception]
        ])

      on_exit(fn -> :telemetry.detach(ref) end)

      expect(RPC, :call, fn ^primary_node, _fun, _timeout ->
        :erlang.error({:erpc, :timeout})
      end)

      resolution = %Resolution{
        repo: TestRepo,
        action: :update,
        args: [],
        middleware: [],
        private: %{
          __super__: fn _resource, _resolution -> {:ok, %{id: 2}} end
        }
      }

      Middleware.process(:changeset, resolution)

      assert_receive {[:ecto_litefs, :forward, :start], ^ref, _measurements, _metadata}

      assert_receive {[:ecto_litefs, :forward, :exception], ^ref, measurements, metadata}
      assert is_integer(measurements.duration)
      assert measurements.duration > 0
      assert metadata.repo == TestRepo
      assert metadata.action == :update
      assert metadata.primary_node == primary_node
      assert metadata.reason == :timeout
    end

    test "does not emit events when executing locally on primary" do
      :ok = EctoLiteFS.set_primary(TestRepo, node())

      ref =
        TelemetryHelper.attach_event_handlers(self(), [
          [:ecto_litefs, :forward, :start],
          [:ecto_litefs, :forward, :stop],
          [:ecto_litefs, :forward, :exception]
        ])

      on_exit(fn -> :telemetry.detach(ref) end)

      reject(&RPC.call/3)

      resolution = %Resolution{
        repo: TestRepo,
        action: :insert,
        args: [],
        middleware: [],
        private: %{
          __super__: fn _resource, _resolution -> {:ok, %{id: 3}} end
        }
      }

      Middleware.process(:changeset, resolution)

      refute_receive {[:ecto_litefs, :forward, :start], ^ref, _, _}, 100
    end
  end
end
