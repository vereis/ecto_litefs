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

  describe "get_tracker!/1" do
    test "returns correct pid" do
      {_temp_dir, primary_file} = create_temp_primary_file()

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          primary_file: primary_file,
          poll_interval: 60_000
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(Repo) end)

      expected_pid = Process.whereis(Tracker.process_name(Repo))
      assert EctoLiteFS.get_tracker!(Repo) == expected_pid

      Supervisor.stop(sup)
    end

    test "raises when repo not registered" do
      assert_raise ArgumentError, ~r/no EctoLiteFS tracker registered for/, fn ->
        EctoLiteFS.get_tracker!(SomeOtherRepo)
      end
    end
  end

  describe "tracker_ready?/1" do
    test "returns false when repo not running" do
      refute EctoLiteFS.tracker_ready?(SomeNonexistentRepo)
    end

    test "returns true when tracker is initialized" do
      {_temp_dir, primary_file} = create_temp_primary_file()

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          primary_file: primary_file,
          poll_interval: 60_000
        )

      eventually(fn -> assert EctoLiteFS.tracker_ready?(Repo) end)

      Supervisor.stop(sup)
    end
  end
end
