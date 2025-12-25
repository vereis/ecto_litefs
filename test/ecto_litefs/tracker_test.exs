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

  describe "set_primary/2" do
    test "writes correct data to DB" do
      {_temp_dir, primary_file} = create_temp_primary_file()
      name = unique_name(:set_primary_db)
      table_name = unique_table_name("_set_primary")

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          name: name,
          primary_file: primary_file,
          poll_interval: 60_000,
          table_name: table_name
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(name) end)

      assert :ok = Tracker.set_primary(name, :test_node@host)

      {:ok, result} = Repo.query("SELECT node_name FROM #{table_name} WHERE id = 1")
      assert result.rows == [["test_node@host"]]

      Supervisor.stop(sup)
    end

    test "updates ETS cache correctly" do
      {_temp_dir, primary_file} = create_temp_primary_file()
      name = unique_name(:set_primary_ets)

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          name: name,
          primary_file: primary_file,
          poll_interval: 60_000
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(name) end)

      assert :ok = Tracker.set_primary(name, :test_node@host)

      ets_table = Tracker.ets_table_name(name)
      [{:primary_info, node, _cached_at, _ttl}] = :ets.lookup(ets_table, :primary_info)
      assert node == :test_node@host

      Supervisor.stop(sup)
    end
  end

  describe "get_primary/1" do
    test "returns cached value when fresh" do
      {_temp_dir, primary_file} = create_temp_primary_file()
      name = unique_name(:get_primary_cached)

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          name: name,
          primary_file: primary_file,
          poll_interval: 60_000,
          cache_ttl: 10_000
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(name) end)

      Tracker.set_primary(name, :cached_node@host)

      assert {:ok, :cached_node@host} = Tracker.get_primary(name)

      Supervisor.stop(sup)
    end

    test "reads directly from ETS cache when fresh" do
      {_temp_dir, primary_file} = create_temp_primary_file()
      name = unique_name(:get_primary_ets)
      table_name = unique_table_name("_get_primary_ets")

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          name: name,
          primary_file: primary_file,
          poll_interval: 60_000,
          table_name: table_name,
          cache_ttl: 60_000
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(name) end)

      Tracker.set_primary(name, :old_node@host)

      Repo.query!("UPDATE #{table_name} SET node_name = 'new_node@host' WHERE id = 1")

      # Cache is fresh, so returns cached value
      assert {:ok, :old_node@host} = Tracker.get_primary(name)

      Supervisor.stop(sup)
    end

    test "refreshes from DB when cache is stale" do
      {_temp_dir, primary_file} = create_temp_primary_file()
      name = unique_name(:get_primary_stale)
      table_name = unique_table_name("_get_primary_stale")

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          name: name,
          primary_file: primary_file,
          poll_interval: 60_000,
          table_name: table_name,
          cache_ttl: 1
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(name) end)

      Tracker.set_primary(name, :old_node@host)
      Process.sleep(10)

      Repo.query!("UPDATE #{table_name} SET node_name = 'new_node@host' WHERE id = 1")

      # Cache is stale (TTL=1ms), so refreshes from DB
      assert {:ok, :new_node@host} = Tracker.get_primary(name)

      Supervisor.stop(sup)
    end

    test "returns nil when no primary recorded" do
      {_temp_dir, primary_file} = create_temp_primary_file()
      name = unique_name(:get_primary_nil)

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          name: name,
          primary_file: primary_file,
          poll_interval: 60_000
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(name) end)

      assert {:ok, nil} = Tracker.get_primary(name)

      Supervisor.stop(sup)
    end
  end

  describe "is_primary?/1" do
    test "returns true when current node is primary" do
      {_temp_dir, primary_file} = create_temp_primary_file()
      name = unique_name(:is_primary_true)

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          name: name,
          primary_file: primary_file,
          poll_interval: 60_000
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(name) end)

      Tracker.set_primary(name, Node.self())

      assert Tracker.is_primary?(name) == true

      Supervisor.stop(sup)
    end

    test "returns false when different node is primary" do
      {_temp_dir, primary_file} = create_temp_primary_file()
      name = unique_name(:is_primary_false)

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          name: name,
          primary_file: primary_file,
          poll_interval: 60_000
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(name) end)

      Tracker.set_primary(name, :other_node@host)

      assert Tracker.is_primary?(name) == false

      Supervisor.stop(sup)
    end

    test "returns false when no primary recorded" do
      {_temp_dir, primary_file} = create_temp_primary_file()
      name = unique_name(:is_primary_nil)

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          name: name,
          primary_file: primary_file,
          poll_interval: 60_000
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(name) end)

      assert Tracker.is_primary?(name) == false

      Supervisor.stop(sup)
    end
  end

  describe "invalidate_cache/1" do
    test "clears ETS cache forcing DB refresh on next read" do
      {_temp_dir, primary_file} = create_temp_primary_file()
      name = unique_name(:invalidate_cache)
      table_name = unique_table_name("_invalidate_cache")

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          name: name,
          primary_file: primary_file,
          poll_interval: 60_000,
          table_name: table_name
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(name) end)

      Tracker.set_primary(name, :old_node@host)
      assert {:ok, :old_node@host} = Tracker.get_primary(name)

      # Update DB directly
      Repo.query!("UPDATE #{table_name} SET node_name = 'new_node@host' WHERE id = 1")

      # Cache still returns old value
      assert {:ok, :old_node@host} = Tracker.get_primary(name)

      # Invalidate forces next read to hit DB
      Tracker.invalidate_cache(name)

      assert {:ok, :new_node@host} = Tracker.get_primary(name)

      Supervisor.stop(sup)
    end
  end

  describe "set_replica/1" do
    test "refreshes cache from DB" do
      {_temp_dir, primary_file} = create_temp_primary_file()
      name = unique_name(:set_replica)
      table_name = unique_table_name("_set_replica")

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          name: name,
          primary_file: primary_file,
          poll_interval: 60_000,
          table_name: table_name
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(name) end)

      Tracker.set_primary(name, :old_node@host)
      assert {:ok, :old_node@host} = Tracker.get_primary(name)

      Repo.query!("UPDATE #{table_name} SET node_name = 'new_node@host' WHERE id = 1")

      assert {:ok, :old_node@host} = Tracker.get_primary(name)

      Tracker.set_replica(name)

      assert {:ok, :new_node@host} = Tracker.get_primary(name)

      Supervisor.stop(sup)
    end

    test "clears cache when no primary in DB" do
      {_temp_dir, primary_file} = create_temp_primary_file()
      name = unique_name(:set_replica_nil)
      table_name = unique_table_name("_set_replica_nil")

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          name: name,
          primary_file: primary_file,
          poll_interval: 60_000,
          table_name: table_name
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(name) end)

      Tracker.set_primary(name, :old_node@host)
      assert {:ok, :old_node@host} = Tracker.get_primary(name)

      Repo.query!("DELETE FROM #{table_name} WHERE id = 1")

      Tracker.set_replica(name)

      assert {:ok, nil} = Tracker.get_primary(name)

      Supervisor.stop(sup)
    end
  end

  describe "Poller integration" do
    test "Poller detection triggers Tracker update" do
      {_temp_dir, primary_file} = create_temp_primary_file()
      name = unique_name(:poller_integration)

      File.rm(primary_file)

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          name: name,
          primary_file: primary_file,
          poll_interval: 50
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(name) end)

      eventually(fn ->
        assert {:ok, Node.self()} == Tracker.get_primary(name)
      end)

      Supervisor.stop(sup)
    end

    test "Poller invalidates cache when becoming replica" do
      {:ok, temp_dir} = Briefly.create(type: :directory)
      primary_file = Path.join(temp_dir, ".primary")
      name = unique_name(:poller_replica)
      table_name = unique_table_name("_poller_replica")

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          name: name,
          primary_file: primary_file,
          poll_interval: 50,
          cache_ttl: 60_000,
          table_name: table_name
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(name) end)

      eventually(fn ->
        assert Tracker.is_primary?(name) == true
      end)

      Repo.query!("UPDATE #{table_name} SET node_name = 'other_node@host' WHERE id = 1")

      assert Tracker.is_primary?(name) == true

      File.write!(primary_file, "other-node")

      eventually(fn ->
        assert Tracker.is_primary?(name) == false
      end)

      Supervisor.stop(sup)
    end
  end
end
