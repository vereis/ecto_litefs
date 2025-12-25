defmodule EctoLiteFS.TrackerTest do
  use EctoLiteFS.Case, async: false

  describe "start_link/1" do
    test "creates ETS table on init" do
      {_temp_dir, primary_file} = create_temp_primary_file()
      name = unique_name(:tracker_ets)

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          name: name,
          primary_file: primary_file,
          poll_interval: 60_000
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(name) end)

      ets_table = Tracker.ets_table_name(name)
      assert :ets.info(ets_table) != :undefined

      Supervisor.stop(sup)
    end

    test "ETS table has correct options" do
      {_temp_dir, primary_file} = create_temp_primary_file()
      name = unique_name(:tracker_ets_opts)

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          name: name,
          primary_file: primary_file,
          poll_interval: 60_000
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(name) end)

      ets_table = Tracker.ets_table_name(name)
      info = :ets.info(ets_table)

      assert Keyword.get(info, :type) == :set
      assert Keyword.get(info, :named_table) == true
      assert Keyword.get(info, :protection) == :public
      assert Keyword.get(info, :read_concurrency) == true

      Supervisor.stop(sup)
    end

    test "creates DB table if not exists" do
      {_temp_dir, primary_file} = create_temp_primary_file()
      name = unique_name(:tracker_db_create)
      table_name = unique_table_name("_ecto_litefs_create")

      drop_table_if_exists(table_name)

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          name: name,
          primary_file: primary_file,
          poll_interval: 60_000,
          table_name: table_name
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(name) end)
      assert table_exists?(table_name)

      Supervisor.stop(sup)
    end

    test "is idempotent - does not fail if DB table already exists" do
      {_temp_dir, primary_file} = create_temp_primary_file()
      name = unique_name(:tracker_idempotent)
      table_name = unique_table_name("_ecto_litefs_idempotent")

      drop_table_if_exists(table_name)
      create_table(table_name)

      assert table_exists?(table_name)

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          name: name,
          primary_file: primary_file,
          poll_interval: 60_000,
          table_name: table_name
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(name) end)
      assert table_exists?(table_name)

      Supervisor.stop(sup)
    end

    test "registers itself for repo lookup" do
      {_temp_dir, primary_file} = create_temp_primary_file()
      name = unique_name(:tracker_registry)

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          name: name,
          primary_file: primary_file,
          poll_interval: 60_000
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(name) end)

      tracker_pid = EctoLiteFS.get_tracker!(name, Repo)
      assert is_pid(tracker_pid)
      assert Process.alive?(tracker_pid)

      Supervisor.stop(sup)
    end
  end

  describe "process_name/1" do
    test "returns module-based name for instance" do
      assert Tracker.process_name(:my_litefs) == :"Elixir.EctoLiteFS.Tracker.my_litefs"
      assert Tracker.process_name(:other) == :"Elixir.EctoLiteFS.Tracker.other"
    end
  end

  describe "ets_table_name/1" do
    test "returns prefixed atom for instance" do
      assert Tracker.ets_table_name(:my_litefs) == :ecto_litefs_my_litefs
      assert Tracker.ets_table_name(:other) == :ecto_litefs_other
    end
  end

  describe "multiple instances" do
    test "ETS table names are derived from instance name" do
      assert Tracker.ets_table_name(:instance_a) == :ecto_litefs_instance_a
      assert Tracker.ets_table_name(:instance_b) == :ecto_litefs_instance_b
      assert Tracker.ets_table_name(:instance_a) != Tracker.ets_table_name(:instance_b)
    end

    test "process names are derived from instance name" do
      assert Tracker.process_name(:instance_a) != Tracker.process_name(:instance_b)
    end
  end

  describe "duplicate repo registration" do
    test "second tracker for same repo fails and get_tracker returns first" do
      Process.flag(:trap_exit, true)

      {_temp_dir1, primary_file1} = create_temp_primary_file()
      {_temp_dir2, primary_file2} = create_temp_primary_file()
      name1 = unique_name(:dup_reg_1)
      name2 = unique_name(:dup_reg_2)

      {:ok, sup1} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          name: name1,
          primary_file: primary_file1,
          poll_interval: 60_000,
          table_name: unique_table_name("_dup_1")
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(name1) end)
      first_tracker = EctoLiteFS.get_tracker!(name1, Repo)

      {:ok, sup2} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          name: name2,
          primary_file: primary_file2,
          poll_interval: 60_000,
          table_name: unique_table_name("_dup_2")
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(name2) end)

      assert EctoLiteFS.get_tracker!(name1, Repo) == first_tracker
      assert EctoLiteFS.get_tracker!(name2, Repo) != first_tracker

      Supervisor.stop(sup2)
      Supervisor.stop(sup1)
    end
  end

  describe "ETS table cleanup" do
    test "ETS table is deleted when tracker stops" do
      {_temp_dir, primary_file} = create_temp_primary_file()
      name = unique_name(:tracker_cleanup)

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          name: name,
          primary_file: primary_file,
          poll_interval: 60_000
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(name) end)

      ets_table = Tracker.ets_table_name(name)
      assert :ets.info(ets_table) != :undefined

      Supervisor.stop(sup)

      eventually(fn -> assert :ets.info(ets_table) == :undefined end)
    end
  end

  describe "Config validation" do
    test "rejects invalid table_name with SQL injection attempt" do
      assert_raise ArgumentError, ~r/must be a valid SQL identifier/, fn ->
        Config.new!(
          repo: Repo,
          name: :sql_injection_test,
          table_name: "foo; DROP TABLE users; --"
        )
      end
    end

    test "accepts valid table_name" do
      config =
        Config.new!(
          repo: Repo,
          name: :valid_table_test,
          table_name: "_my_valid_table_123"
        )

      assert config.table_name == "_my_valid_table_123"
    end
  end
end
