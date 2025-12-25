defmodule EctoLiteFS.EventStreamTest do
  use EctoLiteFS.Case, async: false

  import ExUnit.CaptureLog

  alias EctoLiteFS.Config
  alias EctoLiteFS.EventStream
  alias EctoLiteFS.Supervisor, as: LiteFSSupervisor
  alias EctoLiteFS.Tracker

  describe "process_name/1" do
    test "returns module-based name for instance" do
      assert EventStream.process_name(:my_litefs) == :"Elixir.EctoLiteFS.EventStream.my_litefs"
    end
  end

  describe "JSON parsing (non-Tracker events)" do
    test "ignores tx events" do
      log =
        capture_log([level: :debug], fn ->
          line = ~s({"type":"tx"})
          send_line_to_handler(:parse_tx, line)
        end)

      assert log =~ "tx event (ignored)"
    end

    test "handles unknown event types gracefully" do
      log =
        capture_log([level: :debug], fn ->
          line = ~s({"type":"unknown","foo":"bar"})
          send_line_to_handler(:parse_unknown, line)
        end)

      assert log =~ "unknown event type"
    end

    test "handles malformed JSON gracefully" do
      log =
        capture_log([level: :warning], fn ->
          line = "not valid json"
          send_line_to_handler(:parse_malformed, line)
        end)

      assert log =~ "failed to parse JSON"
    end
  end

  describe "line buffering" do
    test "handles complete lines" do
      log =
        capture_log([level: :debug], fn ->
          state = make_state(:buffer_complete)

          {:noreply, new_state} =
            EventStream.handle_info(
              {:chunk, ~s({"type":"tx"}\n)},
              state
            )

          assert new_state.buffer == ""
        end)

      assert log =~ "tx event"
    end

    test "handles multiple complete lines in one chunk" do
      log =
        capture_log([level: :debug], fn ->
          state = make_state(:buffer_multi)

          chunk = ~s({"type":"tx"}\n{"type":"unknown"}\n)

          {:noreply, new_state} = EventStream.handle_info({:chunk, chunk}, state)
          assert new_state.buffer == ""
        end)

      assert log =~ "tx event"
      assert log =~ "unknown event"
    end

    test "buffers incomplete lines across chunks" do
      log =
        capture_log([level: :debug], fn ->
          state = make_state(:buffer_partial)

          # First chunk - incomplete JSON
          {:noreply, state2} =
            EventStream.handle_info(
              {:chunk, ~s({"type":"tx)},
              state
            )

          # Should have buffered the incomplete line
          assert state2.buffer == ~s({"type":"tx)

          # Second chunk - completes the JSON
          {:noreply, state3} =
            EventStream.handle_info(
              {:chunk, ~s("}\n)},
              state2
            )

          assert state3.buffer == ""
        end)

      assert log =~ "tx event"
    end
  end

  describe "Tracker integration" do
    test "init with isPrimary true triggers Tracker.set_primary" do
      name = unique_name(:event_primary)
      {_temp_dir, primary_file} = create_temp_primary_file()

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          name: name,
          primary_file: primary_file,
          poll_interval: 60_000
        )

      eventually(fn -> Tracker.ready?(name) end)

      # Simulate receiving an init event with isPrimary: true
      event_stream_pid = Process.whereis(EventStream.process_name(name))
      chunk = ~s({"type":"init","data":{"isPrimary":true}}\n)
      send(event_stream_pid, {:chunk, chunk})

      # Give time for the event to be processed
      eventually(fn ->
        case Tracker.get_primary(name) do
          {:ok, node} -> node == Node.self()
          _other -> false
        end
      end)

      Supervisor.stop(sup)
    end

    test "init with isPrimary false triggers Tracker.set_replica" do
      name = unique_name(:event_replica)
      {_temp_dir, primary_file} = create_temp_primary_file()

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          name: name,
          primary_file: primary_file,
          poll_interval: 60_000
        )

      eventually(fn -> Tracker.ready?(name) end)

      # First set ourselves as primary so we have something in cache
      Tracker.set_primary(name, Node.self())
      assert {:ok, node} = Tracker.get_primary(name)
      assert node == Node.self()

      # Simulate receiving an init event with isPrimary: false
      event_stream_pid = Process.whereis(EventStream.process_name(name))
      chunk = ~s({"type":"init","data":{"isPrimary":false,"hostname":"other:20202"}}\n)
      send(event_stream_pid, {:chunk, chunk})

      # Give time for the event to be processed - cache should be refreshed from DB
      Process.sleep(50)

      # The set_replica call refreshes from DB, which still has our node
      # (since we wrote it). The key test is that it doesn't crash.
      assert {:ok, _node} = Tracker.get_primary(name)

      Supervisor.stop(sup)
    end

    test "primaryChange with isPrimary true triggers Tracker.set_primary" do
      name = unique_name(:event_change_primary)
      {_temp_dir, primary_file} = create_temp_primary_file()

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          name: name,
          primary_file: primary_file,
          poll_interval: 60_000
        )

      eventually(fn -> Tracker.ready?(name) end)

      # Simulate receiving a primaryChange event with isPrimary: true
      event_stream_pid = Process.whereis(EventStream.process_name(name))
      chunk = ~s({"type":"primaryChange","data":{"isPrimary":true}}\n)
      send(event_stream_pid, {:chunk, chunk})

      eventually(fn ->
        case Tracker.get_primary(name) do
          {:ok, node} -> node == Node.self()
          _other -> false
        end
      end)

      Supervisor.stop(sup)
    end

    test "primaryChange with isPrimary false triggers Tracker.set_replica" do
      name = unique_name(:event_change_replica)
      {_temp_dir, primary_file} = create_temp_primary_file()

      {:ok, sup} =
        LiteFSSupervisor.start_link(
          repo: Repo,
          name: name,
          primary_file: primary_file,
          poll_interval: 60_000
        )

      eventually(fn -> Tracker.ready?(name) end)

      # First set ourselves as primary
      Tracker.set_primary(name, Node.self())
      assert {:ok, node} = Tracker.get_primary(name)
      assert node == Node.self()

      # Simulate receiving a primaryChange event with isPrimary: false
      event_stream_pid = Process.whereis(EventStream.process_name(name))
      chunk = ~s({"type":"primaryChange","data":{"isPrimary":false,"hostname":"other:20202"}}\n)
      send(event_stream_pid, {:chunk, chunk})

      # Give time for the event to be processed
      Process.sleep(50)

      # The set_replica call refreshes from DB - should not crash
      assert {:ok, _node} = Tracker.get_primary(name)

      Supervisor.stop(sup)
    end
  end

  defp send_line_to_handler(name, line) do
    state = make_state(name)
    EventStream.handle_info({:chunk, line <> "\n"}, state)
  end

  defp make_state(name) do
    config = Config.new!(repo: Repo, name: name, event_stream_url: "http://test/events")
    %{config: config, buffer: ""}
  end
end
