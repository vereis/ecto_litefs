defmodule EctoLiteFS.SupervisorTest do
  use EctoLiteFS.Case, async: false

  describe "start_link/1" do
    test "starts supervisor with poller and tracker" do
      {_temp_dir, primary_file} = create_temp_primary_file()
      name = unique_name(:sup)

      {:ok, sup_pid} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          name: name,
          primary_file: primary_file,
          poll_interval: 60_000
        )

      assert Process.alive?(sup_pid)

      eventually(fn -> assert EctoLiteFS.tracker_ready?(name) end)

      poller_pid = Process.whereis(Poller.process_name(name))
      assert poller_pid
      assert Process.alive?(poller_pid)

      tracker_pid = Process.whereis(Tracker.process_name(name))
      assert tracker_pid
      assert Process.alive?(tracker_pid)

      Supervisor.stop(sup_pid)
    end

    test "registers supervisor with correct name" do
      {_temp_dir, primary_file} = create_temp_primary_file()
      name = unique_name(:sup_name)

      {:ok, sup_pid} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          name: name,
          primary_file: primary_file,
          poll_interval: 60_000
        )

      assert Process.whereis(LiteFSSupervisor.supervisor_name(name)) == sup_pid

      Supervisor.stop(sup_pid)
    end

    test "starts registry as child" do
      {_temp_dir, primary_file} = create_temp_primary_file()
      name = unique_name(:sup_registry)

      {:ok, sup_pid} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          name: name,
          primary_file: primary_file,
          poll_interval: 60_000
        )

      registry_name = EctoLiteFS.registry_name(name)
      assert Process.whereis(registry_name)

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
      {_temp_dir1, primary_file1} = create_temp_primary_file()
      {_temp_dir2, primary_file2} = create_temp_primary_file()
      name1 = unique_name(:multi_1)
      name2 = unique_name(:multi_2)

      {:ok, sup1} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          name: name1,
          primary_file: primary_file1,
          poll_interval: 60_000,
          table_name: unique_table_name("_sup_multi_1")
        )

      {:ok, sup2} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          name: name2,
          primary_file: primary_file2,
          poll_interval: 60_000,
          table_name: unique_table_name("_sup_multi_2")
        )

      assert Process.alive?(sup1)
      assert Process.alive?(sup2)
      assert sup1 != sup2

      eventually(fn -> assert EctoLiteFS.tracker_ready?(name1) end)
      eventually(fn -> assert EctoLiteFS.tracker_ready?(name2) end)

      poller1 = Process.whereis(Poller.process_name(name1))
      poller2 = Process.whereis(Poller.process_name(name2))

      assert poller1
      assert poller2
      assert poller1 != poller2

      tracker1 = Process.whereis(Tracker.process_name(name1))
      tracker2 = Process.whereis(Tracker.process_name(name2))

      assert tracker1
      assert tracker2
      assert tracker1 != tracker2

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
