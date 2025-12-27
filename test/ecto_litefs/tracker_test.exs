defmodule EctoLiteFS.TrackerTest do
  use EctoLiteFS.Case, async: false

  describe "start_link/1" do
    test "creates ETS table on init" do
      {_temp_dir, primary_file} = create_temp_primary_file()

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          primary_file: primary_file,
          poll_interval: 60_000
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(Repo) end)

      ets_table = Tracker.ets_table_name(Repo)
      assert :ets.info(ets_table) != :undefined

      Supervisor.stop(sup)
    end

    test "ETS table has correct options" do
      {_temp_dir, primary_file} = create_temp_primary_file()

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          primary_file: primary_file,
          poll_interval: 60_000
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(Repo) end)

      ets_table = Tracker.ets_table_name(Repo)
      info = :ets.info(ets_table)

      assert Keyword.get(info, :type) == :set
      assert Keyword.get(info, :named_table) == true
      assert Keyword.get(info, :protection) == :public
      assert Keyword.get(info, :read_concurrency) == true

      Supervisor.stop(sup)
    end

    test "creates DB table if not exists" do
      {_temp_dir, primary_file} = create_temp_primary_file()
      table_name = unique_table_name("_ecto_litefs_create")

      drop_table_if_exists(table_name)

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          primary_file: primary_file,
          poll_interval: 60_000,
          table_name: table_name
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(Repo) end)
      assert table_exists?(table_name)

      Supervisor.stop(sup)
    end

    test "is idempotent - does not fail if DB table already exists" do
      {_temp_dir, primary_file} = create_temp_primary_file()
      table_name = unique_table_name("_ecto_litefs_idempotent")

      drop_table_if_exists(table_name)
      create_table(table_name)

      assert table_exists?(table_name)

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          primary_file: primary_file,
          poll_interval: 60_000,
          table_name: table_name
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(Repo) end)
      assert table_exists?(table_name)

      Supervisor.stop(sup)
    end

    test "registers itself for repo lookup" do
      {_temp_dir, primary_file} = create_temp_primary_file()

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          primary_file: primary_file,
          poll_interval: 60_000
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(Repo) end)

      tracker_pid = EctoLiteFS.get_tracker!(Repo)
      assert is_pid(tracker_pid)
      assert Process.alive?(tracker_pid)

      Supervisor.stop(sup)
    end
  end

  describe "process_name/1" do
    test "returns module-based name for repo" do
      assert Tracker.process_name(MyApp.Repo) == :"Elixir.EctoLiteFS.Tracker.MyApp.Repo"
      assert Tracker.process_name(OtherRepo) == :"Elixir.EctoLiteFS.Tracker.OtherRepo"
    end
  end

  describe "ets_table_name/1" do
    test "returns repo-based ETS table name" do
      assert Tracker.ets_table_name(MyApp.Repo) == :"Elixir.EctoLiteFS.MyApp.Repo.ETS"
      assert Tracker.ets_table_name(OtherRepo) == :"Elixir.EctoLiteFS.OtherRepo.ETS"
    end
  end

  describe "multiple repos" do
    test "ETS table names are derived from repo module" do
      assert Tracker.ets_table_name(RepoA) == :"Elixir.EctoLiteFS.RepoA.ETS"
      assert Tracker.ets_table_name(RepoB) == :"Elixir.EctoLiteFS.RepoB.ETS"
      assert Tracker.ets_table_name(RepoA) != Tracker.ets_table_name(RepoB)
    end

    test "process names are derived from instance name" do
      assert Tracker.process_name(:instance_a) != Tracker.process_name(:instance_b)
    end
  end

  describe "duplicate repo registration" do
    test "second supervisor for same repo fails to start" do
      {_temp_dir1, primary_file1} = create_temp_primary_file()
      {_temp_dir2, primary_file2} = create_temp_primary_file()

      {:ok, sup1} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          primary_file: primary_file1,
          poll_interval: 60_000,
          table_name: unique_table_name("_dup_1")
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(Repo) end)
      first_tracker = EctoLiteFS.get_tracker!(Repo)

      # Second supervisor for same repo should fail because process name is already taken
      assert {:error, {:already_started, _pid}} =
               LiteFSSupervisor.start_link(
                 repo: Repo,
                 primary_file: primary_file2,
                 poll_interval: 60_000,
                 table_name: unique_table_name("_dup_2")
               )

      # First tracker is still running
      assert EctoLiteFS.get_tracker!(Repo) == first_tracker

      Supervisor.stop(sup1)
    end
  end

  describe "ETS table cleanup" do
    test "ETS table is deleted when tracker stops" do
      {_temp_dir, primary_file} = create_temp_primary_file()

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          primary_file: primary_file,
          poll_interval: 60_000
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(Repo) end)

      ets_table = Tracker.ets_table_name(Repo)
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
          table_name: "foo; DROP TABLE users; --"
        )
      end
    end

    test "accepts valid table_name" do
      config =
        Config.new!(
          repo: Repo,
          table_name: "_my_valid_table_123"
        )

      assert config.table_name == "_my_valid_table_123"
    end
  end

  describe "set_primary/2" do
    test "writes correct data to DB" do
      {_temp_dir, primary_file} = create_temp_primary_file()
      table_name = unique_table_name("_set_primary")

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          primary_file: primary_file,
          poll_interval: 60_000,
          table_name: table_name
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(Repo) end)

      assert :ok = Tracker.set_primary(Repo, :test_node@host)

      {:ok, result} = Repo.query("SELECT node_name FROM #{table_name} WHERE id = 1")
      assert result.rows == [["test_node@host"]]

      Supervisor.stop(sup)
    end

    test "updates ETS cache correctly" do
      {_temp_dir, primary_file} = create_temp_primary_file()

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          primary_file: primary_file,
          poll_interval: 60_000
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(Repo) end)

      assert :ok = Tracker.set_primary(Repo, :test_node@host)

      ets_table = Tracker.ets_table_name(Repo)
      [{:primary_info, node, _cached_at, _ttl}] = :ets.lookup(ets_table, :primary_info)
      assert node == :test_node@host

      Supervisor.stop(sup)
    end
  end

  describe "get_primary/1" do
    test "returns cached value when fresh" do
      {_temp_dir, primary_file} = create_temp_primary_file()

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          primary_file: primary_file,
          poll_interval: 60_000,
          cache_ttl: 10_000
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(Repo) end)

      Tracker.set_primary(Repo, :cached_node@host)

      assert {:ok, :cached_node@host} = Tracker.get_primary(Repo)

      Supervisor.stop(sup)
    end

    test "reads directly from ETS cache when fresh" do
      {_temp_dir, primary_file} = create_temp_primary_file()
      table_name = unique_table_name("_get_primary_ets")

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          primary_file: primary_file,
          poll_interval: 60_000,
          table_name: table_name,
          cache_ttl: 60_000
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(Repo) end)

      Tracker.set_primary(Repo, :old_node@host)

      Repo.query!("UPDATE #{table_name} SET node_name = 'new_node@host' WHERE id = 1")

      # Cache is fresh, so returns cached value
      assert {:ok, :old_node@host} = Tracker.get_primary(Repo)

      Supervisor.stop(sup)
    end

    test "refreshes from DB when cache is stale" do
      {_temp_dir, primary_file} = create_temp_primary_file()
      table_name = unique_table_name("_get_primary_stale")

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          primary_file: primary_file,
          poll_interval: 60_000,
          table_name: table_name,
          cache_ttl: 1
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(Repo) end)

      current_node = Node.self()
      Tracker.set_primary(Repo, current_node)

      assert {:ok, ^current_node} = Tracker.get_primary(Repo)

      Repo.query!("DELETE FROM #{table_name} WHERE id = 1")

      Process.sleep(10)

      assert {:ok, nil} = Tracker.get_primary(Repo)

      Supervisor.stop(sup)
    end

    test "returns nil when no primary recorded" do
      {_temp_dir, primary_file} = create_temp_primary_file()

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          primary_file: primary_file,
          poll_interval: 60_000
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(Repo) end)

      assert {:ok, nil} = Tracker.get_primary(Repo)

      Supervisor.stop(sup)
    end
  end

  describe "is_primary?/1" do
    test "returns true when current node is primary" do
      {_temp_dir, primary_file} = create_temp_primary_file()

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          primary_file: primary_file,
          poll_interval: 60_000
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(Repo) end)

      Tracker.set_primary(Repo, Node.self())

      assert Tracker.is_primary?(Repo) == true

      Supervisor.stop(sup)
    end

    test "returns false when different node is primary" do
      {_temp_dir, primary_file} = create_temp_primary_file()

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          primary_file: primary_file,
          poll_interval: 60_000
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(Repo) end)

      Tracker.set_primary(Repo, :other_node@host)

      assert Tracker.is_primary?(Repo) == false

      Supervisor.stop(sup)
    end

    test "returns false when no primary recorded" do
      {_temp_dir, primary_file} = create_temp_primary_file()

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          primary_file: primary_file,
          poll_interval: 60_000
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(Repo) end)

      assert Tracker.is_primary?(Repo) == false

      Supervisor.stop(sup)
    end
  end

  describe "invalidate_cache/1" do
    test "clears ETS cache forcing DB refresh on next read" do
      {_temp_dir, primary_file} = create_temp_primary_file()
      table_name = unique_table_name("_invalidate_cache")

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          primary_file: primary_file,
          poll_interval: 60_000,
          table_name: table_name
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(Repo) end)

      current_node = Node.self()
      Tracker.set_primary(Repo, current_node)
      assert {:ok, ^current_node} = Tracker.get_primary(Repo)

      Repo.query!("DELETE FROM #{table_name} WHERE id = 1")

      assert {:ok, ^current_node} = Tracker.get_primary(Repo)

      Tracker.invalidate_cache(Repo)

      assert {:ok, nil} = Tracker.get_primary(Repo)

      Supervisor.stop(sup)
    end
  end

  describe "set_replica/1" do
    test "refreshes cache from DB" do
      {_temp_dir, primary_file} = create_temp_primary_file()
      table_name = unique_table_name("_set_replica")

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          primary_file: primary_file,
          poll_interval: 60_000,
          table_name: table_name
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(Repo) end)

      current_node = Node.self()
      Tracker.set_primary(Repo, current_node)
      assert {:ok, ^current_node} = Tracker.get_primary(Repo)

      Repo.query!("DELETE FROM #{table_name} WHERE id = 1")

      assert {:ok, ^current_node} = Tracker.get_primary(Repo)

      Tracker.set_replica(Repo)

      assert {:ok, nil} = Tracker.get_primary(Repo)

      Supervisor.stop(sup)
    end

    test "clears cache when no primary in DB" do
      {_temp_dir, primary_file} = create_temp_primary_file()
      table_name = unique_table_name("_set_replica_nil")

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          primary_file: primary_file,
          poll_interval: 60_000,
          table_name: table_name
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(Repo) end)

      Tracker.set_primary(Repo, :old_node@host)
      assert {:ok, :old_node@host} = Tracker.get_primary(Repo)

      Repo.query!("DELETE FROM #{table_name} WHERE id = 1")

      Tracker.set_replica(Repo)

      assert {:ok, nil} = Tracker.get_primary(Repo)

      Supervisor.stop(sup)
    end
  end

  describe "Poller integration" do
    test "Poller detection triggers Tracker update" do
      {_temp_dir, primary_file} = create_temp_primary_file()

      File.rm(primary_file)

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          primary_file: primary_file,
          poll_interval: 50
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(Repo) end)

      eventually(fn ->
        assert {:ok, Node.self()} == Tracker.get_primary(Repo)
      end)

      Supervisor.stop(sup)
    end

    test "Poller invalidates cache when becoming replica" do
      {:ok, temp_dir} = Briefly.create(type: :directory)
      primary_file = Path.join(temp_dir, ".primary")
      table_name = unique_table_name("_poller_replica")

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          primary_file: primary_file,
          poll_interval: 50,
          cache_ttl: 60_000,
          table_name: table_name
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(Repo) end)

      eventually(fn ->
        assert Tracker.is_primary?(Repo) == true
      end)

      Repo.query!("UPDATE #{table_name} SET node_name = 'other_node@host' WHERE id = 1")

      assert Tracker.is_primary?(Repo) == true

      File.write!(primary_file, "other-node")

      eventually(fn ->
        assert Tracker.is_primary?(Repo) == false
      end)

      Supervisor.stop(sup)
    end
  end

  describe "atom safety in refresh_cache_from_db" do
    test "rejects node names not in connected nodes" do
      {_temp_dir, primary_file} = create_temp_primary_file()
      table_name = unique_table_name("_atom_safety")

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          primary_file: primary_file,
          poll_interval: 60_000,
          table_name: table_name
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(Repo) end)

      Repo.query!("INSERT INTO #{table_name} (id, node_name, updated_at) VALUES (1, 'fake_node@invalid', 0)")

      Tracker.invalidate_cache(Repo)
      assert {:ok, nil} = Tracker.get_primary(Repo)

      Supervisor.stop(sup)
    end

    test "accepts node names from connected nodes" do
      {_temp_dir, primary_file} = create_temp_primary_file()
      table_name = unique_table_name("_atom_safety_ok")

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          primary_file: primary_file,
          poll_interval: 60_000,
          table_name: table_name
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(Repo) end)

      node_name = Atom.to_string(Node.self())
      Repo.query!("INSERT INTO #{table_name} (id, node_name, updated_at) VALUES (1, ?, 0)", [node_name])

      Tracker.invalidate_cache(Repo)
      current_node = Node.self()
      assert {:ok, ^current_node} = Tracker.get_primary(Repo)

      Supervisor.stop(sup)
    end
  end

  describe "refresh grace period" do
    test "normal refresh respects grace period but force refresh bypasses it" do
      {_temp_dir, primary_file} = create_temp_primary_file()
      table_name = unique_table_name("_grace_period")

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          primary_file: primary_file,
          poll_interval: 60_000,
          table_name: table_name,
          refresh_grace_period: 500
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(Repo) end)

      current_node = Node.self()
      Tracker.set_primary(Repo, current_node)

      Tracker.invalidate_cache(Repo)

      assert {:ok, ^current_node} = Tracker.get_primary(Repo)

      Repo.query!("DELETE FROM #{table_name} WHERE id = 1")

      assert {:ok, ^current_node} = Tracker.get_primary(Repo)

      assert {:ok, nil} = Tracker.get_primary(Repo, force: true)

      Supervisor.stop(sup)
    end
  end

  describe "get_primary with force option" do
    test "force: true bypasses cache" do
      {_temp_dir, primary_file} = create_temp_primary_file()
      table_name = unique_table_name("_force_refresh")

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          primary_file: primary_file,
          poll_interval: 60_000,
          table_name: table_name,
          cache_ttl: 60_000
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(Repo) end)

      current_node = Node.self()
      Tracker.set_primary(Repo, current_node)
      assert {:ok, ^current_node} = Tracker.get_primary(Repo)

      Repo.query!("DELETE FROM #{table_name} WHERE id = 1")

      assert {:ok, ^current_node} = Tracker.get_primary(Repo)

      assert {:ok, nil} = Tracker.get_primary(Repo, force: true)

      Supervisor.stop(sup)
    end
  end
end
