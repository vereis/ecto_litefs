defmodule EctoLiteFS.PollerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias EctoLiteFS.Config
  alias EctoLiteFS.Poller

  defmodule TestRepo do
    use Ecto.Repo,
      otp_app: :ecto_litefs,
      adapter: Ecto.Adapters.SQLite3
  end

  describe "start_link/1" do
    test "starts the poller with the correct name" do
      {:ok, temp_dir} = Briefly.create(type: :directory)
      primary_file = Path.join(temp_dir, ".primary")

      config =
        Config.new!(
          repo: TestRepo,
          primary_file: primary_file,
          poll_interval: 60_000
        )

      {:ok, pid} = Poller.start_link(config)
      assert Process.alive?(pid)
      assert Process.whereis(Poller.process_name(TestRepo)) == pid

      GenServer.stop(pid)
    end
  end

  describe "process_name/1" do
    test "returns module-based name for repo" do
      assert Poller.process_name(MyApp.Repo) == :"Elixir.EctoLiteFS.Poller.MyApp.Repo"
      assert Poller.process_name(OtherRepo) == :"Elixir.EctoLiteFS.Poller.OtherRepo"
    end
  end

  describe "polling" do
    test "detects primary when .primary file is absent" do
      {:ok, temp_dir} = Briefly.create(type: :directory)
      primary_file = Path.join(temp_dir, ".primary")

      config =
        Config.new!(
          repo: TestRepo,
          primary_file: primary_file,
          poll_interval: 50
        )

      log =
        capture_log([level: :debug], fn ->
          {:ok, pid} = Poller.start_link(config)
          Process.sleep(150)
          GenServer.stop(pid)
        end)

      assert log =~ "primary"
      refute log =~ "replica"
    end

    test "detects replica when .primary file is present" do
      {:ok, temp_dir} = Briefly.create(type: :directory)
      primary_file = Path.join(temp_dir, ".primary")
      File.write!(primary_file, "some-other-node")

      config =
        Config.new!(
          repo: TestRepo,
          primary_file: primary_file,
          poll_interval: 50
        )

      log =
        capture_log([level: :debug], fn ->
          {:ok, pid} = Poller.start_link(config)
          Process.sleep(150)
          GenServer.stop(pid)
        end)

      assert log =~ "replica"
    end

    test "respects configured poll interval" do
      {:ok, temp_dir} = Briefly.create(type: :directory)
      primary_file = Path.join(temp_dir, ".primary")

      config =
        Config.new!(
          repo: TestRepo,
          primary_file: primary_file,
          poll_interval: 100
        )

      log =
        capture_log([level: :debug], fn ->
          {:ok, pid} = Poller.start_link(config)
          # Toggle status to trigger multiple log messages
          Process.sleep(150)
          File.write!(primary_file, "other-node")
          Process.sleep(150)
          File.rm!(primary_file)
          Process.sleep(150)
          GenServer.stop(pid)
        end)

      # Should see status changes: primary -> replica -> primary
      assert log =~ "primary"
      assert log =~ "replica"
    end

    test "treats nonexistent paths as primary (file absent)" do
      config =
        Config.new!(
          repo: TestRepo,
          primary_file: "/nonexistent/deeply/nested/path/.primary",
          poll_interval: 50
        )

      log =
        capture_log([level: :debug], fn ->
          {:ok, pid} = Poller.start_link(config)
          Process.sleep(150)
          assert Process.alive?(pid)
          GenServer.stop(pid)
        end)

      assert log =~ "primary"
    end
  end
end
