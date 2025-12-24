defmodule EctoLiteFS.SupervisorTest do
  use ExUnit.Case, async: true

  alias EctoLiteFS.Poller
  alias EctoLiteFS.Supervisor, as: LiteFSSupervisor

  describe "start_link/1" do
    test "starts supervisor with poller" do
      {:ok, temp_dir} = Briefly.create(type: :directory)
      primary_file = Path.join(temp_dir, ".primary")

      {:ok, sup_pid} =
        LiteFSSupervisor.start_link(
          repo: TestRepo,
          name: :sup_test_1,
          primary_file: primary_file,
          poll_interval: 60_000
        )

      assert Process.alive?(sup_pid)

      poller_pid = Process.whereis(Poller.process_name(:sup_test_1))
      assert poller_pid
      assert Process.alive?(poller_pid)

      Supervisor.stop(sup_pid)
    end

    test "registers supervisor with correct name" do
      {:ok, temp_dir} = Briefly.create(type: :directory)
      primary_file = Path.join(temp_dir, ".primary")

      {:ok, sup_pid} =
        LiteFSSupervisor.start_link(
          repo: TestRepo,
          name: :sup_test_2,
          primary_file: primary_file,
          poll_interval: 60_000
        )

      assert Process.whereis(LiteFSSupervisor.supervisor_name(:sup_test_2)) == sup_pid

      Supervisor.stop(sup_pid)
    end

    test "raises on invalid config" do
      assert_raise ArgumentError, ~r/requires :repo option/, fn ->
        LiteFSSupervisor.start_link(name: :invalid)
      end
    end
  end

  describe "multiple instances" do
    test "can start multiple supervisors with different names" do
      {:ok, temp_dir1} = Briefly.create(type: :directory)
      {:ok, temp_dir2} = Briefly.create(type: :directory)
      primary_file1 = Path.join(temp_dir1, ".primary")
      primary_file2 = Path.join(temp_dir2, ".primary")

      {:ok, sup1} =
        LiteFSSupervisor.start_link(
          repo: TestRepo1,
          name: :multi_test_1,
          primary_file: primary_file1,
          poll_interval: 60_000
        )

      {:ok, sup2} =
        LiteFSSupervisor.start_link(
          repo: TestRepo2,
          name: :multi_test_2,
          primary_file: primary_file2,
          poll_interval: 60_000
        )

      assert Process.alive?(sup1)
      assert Process.alive?(sup2)
      assert sup1 != sup2

      poller1 = Process.whereis(Poller.process_name(:multi_test_1))
      poller2 = Process.whereis(Poller.process_name(:multi_test_2))

      assert poller1
      assert poller2
      assert poller1 != poller2

      Supervisor.stop(sup1)
      Supervisor.stop(sup2)
    end
  end

  describe "supervisor_name/1" do
    test "returns module-based name for instance" do
      assert LiteFSSupervisor.supervisor_name(:my_litefs) == :"Elixir.EctoLiteFS.Supervisor.my_litefs"
    end
  end
end
