defmodule EctoLiteFSTest do
  use EctoLiteFS.Case, async: false

  describe "project setup" do
    test "repo can execute basic queries" do
      assert {:ok, %{rows: [[1]]}} = Repo.query("SELECT 1")
    end

    test "repo is using SQLite adapter" do
      assert Repo.__adapter__() == Ecto.Adapters.SQLite3
    end
  end

  describe "registry_name/1" do
    test "returns module-based registry name for instance" do
      assert EctoLiteFS.registry_name(:my_litefs) == :"Elixir.EctoLiteFS.my_litefs.Registry"
      assert EctoLiteFS.registry_name(:other) == :"Elixir.EctoLiteFS.other.Registry"
    end
  end

  describe "get_tracker!/2" do
    test "returns correct pid" do
      {_temp_dir, primary_file} = create_temp_primary_file()
      name = unique_name(:get_tracker)

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          name: name,
          primary_file: primary_file,
          poll_interval: 60_000
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(name) end)

      expected_pid = Process.whereis(Tracker.process_name(name))
      assert EctoLiteFS.get_tracker!(name, Repo) == expected_pid

      Supervisor.stop(sup)
    end

    test "raises when instance not running" do
      assert_raise ArgumentError, ~r/unknown registry/, fn ->
        EctoLiteFS.get_tracker!(:unknown_instance, SomeRepo)
      end
    end

    test "raises when repo not registered" do
      {_temp_dir, primary_file} = create_temp_primary_file()
      name = unique_name(:get_tracker_unknown)

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          name: name,
          primary_file: primary_file,
          poll_interval: 60_000
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(name) end)

      assert_raise ArgumentError, ~r/no EctoLiteFS tracker registered for/, fn ->
        EctoLiteFS.get_tracker!(name, SomeOtherRepo)
      end

      Supervisor.stop(sup)
    end
  end

  describe "tracker_ready?/1" do
    test "returns false when instance not running" do
      refute EctoLiteFS.tracker_ready?(:nonexistent_instance)
    end

    test "returns true when tracker is initialized" do
      {_temp_dir, primary_file} = create_temp_primary_file()
      name = unique_name(:tracker_ready)

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          name: name,
          primary_file: primary_file,
          poll_interval: 60_000
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(name) end)

      Supervisor.stop(sup)
    end
  end
end
