defmodule EctoLiteFS.SupervisorTest do
  use EctoLiteFS.Case, async: false

  alias Ecto.Adapters.SQLite3

  defmodule TestRepo1 do
    @moduledoc false
    use Ecto.Repo,
      otp_app: :ecto_litefs,
      adapter: SQLite3
  end

  defmodule TestRepo2 do
    @moduledoc false
    use Ecto.Repo,
      otp_app: :ecto_litefs,
      adapter: SQLite3
  end

  describe "start_link/1" do
    test "starts supervisor with poller and tracker" do
      {_temp_dir, primary_file} = create_temp_primary_file()

      {:ok, sup_pid} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          primary_file: primary_file,
          poll_interval: 60_000
        )

      assert Process.alive?(sup_pid)

      eventually(fn -> assert EctoLiteFS.tracker_ready?(Repo) end)

      poller_pid = Process.whereis(Poller.process_name(Repo))
      assert poller_pid
      assert Process.alive?(poller_pid)

      tracker_pid = Process.whereis(Tracker.process_name(Repo))
      assert tracker_pid
      assert Process.alive?(tracker_pid)

      Supervisor.stop(sup_pid)
    end

    test "registers supervisor with correct name" do
      {_temp_dir, primary_file} = create_temp_primary_file()

      {:ok, sup_pid} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          primary_file: primary_file,
          poll_interval: 60_000
        )

      assert Process.whereis(LiteFSSupervisor.supervisor_name(Repo)) == sup_pid

      Supervisor.stop(sup_pid)
    end

    test "raises on invalid config" do
      assert_raise ArgumentError, ~r/requires :repo option/, fn ->
        LiteFSSupervisor.start_link([])
      end
    end
  end

  describe "multiple repos" do
    test "can start multiple supervisors for different repos" do
      # Start test repos
      {:ok, _} = TestRepo1.start_link(database: ":memory:")
      {:ok, _} = TestRepo2.start_link(database: ":memory:")

      {_temp_dir1, primary_file1} = create_temp_primary_file()
      {_temp_dir2, primary_file2} = create_temp_primary_file()

      {:ok, sup1} =
        LiteFSSupervisor.start_link(
          repo: TestRepo1,
          primary_file: primary_file1,
          poll_interval: 60_000,
          table_name: unique_table_name("_sup_multi_1")
        )

      {:ok, sup2} =
        LiteFSSupervisor.start_link(
          repo: TestRepo2,
          primary_file: primary_file2,
          poll_interval: 60_000,
          table_name: unique_table_name("_sup_multi_2")
        )

      assert Process.alive?(sup1)
      assert Process.alive?(sup2)
      assert sup1 != sup2

      eventually(fn -> assert EctoLiteFS.tracker_ready?(TestRepo1) end)
      eventually(fn -> assert EctoLiteFS.tracker_ready?(TestRepo2) end)

      poller1 = Process.whereis(Poller.process_name(TestRepo1))
      poller2 = Process.whereis(Poller.process_name(TestRepo2))

      assert poller1
      assert poller2
      assert poller1 != poller2

      tracker1 = Process.whereis(Tracker.process_name(TestRepo1))
      tracker2 = Process.whereis(Tracker.process_name(TestRepo2))

      assert tracker1
      assert tracker2
      assert tracker1 != tracker2

      Supervisor.stop(sup1)
      Supervisor.stop(sup2)
    end
  end

  describe "supervisor_name/1" do
    test "returns module-based name for repo" do
      assert LiteFSSupervisor.supervisor_name(MyApp.Repo) == :"Elixir.EctoLiteFS.Supervisor.MyApp.Repo"
    end
  end
end
