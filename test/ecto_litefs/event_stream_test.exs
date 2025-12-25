defmodule EctoLiteFS.EventStreamTest do
  use EctoLiteFS.Case, async: false

  import ExUnit.CaptureLog

  alias EctoLiteFS.Config
  alias EctoLiteFS.EventStream

  describe "process_name/1" do
    test "returns module-based name for instance" do
      assert EventStream.process_name(:my_litefs) == :"Elixir.EctoLiteFS.EventStream.my_litefs"
    end
  end

  describe "JSON parsing" do
    test "parses init event with isPrimary true" do
      log =
        capture_log([level: :debug], fn ->
          line = ~s({"type":"init","data":{"isPrimary":true,"hostname":"node1"}})
          send_line_to_handler(:parse_primary, line)
        end)

      assert log =~ "init event"
      assert log =~ "primary"
      assert log =~ "hostname=node1"
    end

    test "parses init event with isPrimary false" do
      log =
        capture_log([level: :debug], fn ->
          line = ~s({"type":"init","data":{"isPrimary":false,"hostname":"node2"}})
          send_line_to_handler(:parse_replica, line)
        end)

      assert log =~ "init event"
      assert log =~ "replica"
    end

    test "parses primaryChange event" do
      log =
        capture_log([level: :debug], fn ->
          line = ~s({"type":"primaryChange","data":{"isPrimary":true,"hostname":"node3"}})
          send_line_to_handler(:parse_change, line)
        end)

      assert log =~ "primaryChange event"
      assert log =~ "primary"
    end

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
              {:chunk, ~s({"type":"init","data":{"isPrimary":true,"hostname":"node1"}}\n)},
              state
            )

          assert new_state.buffer == ""
        end)

      assert log =~ "init event"
    end

    test "handles multiple complete lines in one chunk" do
      log =
        capture_log([level: :debug], fn ->
          state = make_state(:buffer_multi)

          chunk =
            ~s({"type":"init","data":{"isPrimary":true,"hostname":"node1"}}\n{"type":"primaryChange","data":{"isPrimary":false,"hostname":"node2"}}\n)

          {:noreply, new_state} = EventStream.handle_info({:chunk, chunk}, state)
          assert new_state.buffer == ""
        end)

      assert log =~ "init event"
      assert log =~ "primaryChange event"
    end

    test "buffers incomplete lines across chunks" do
      log =
        capture_log([level: :debug], fn ->
          state = make_state(:buffer_partial)

          # First chunk - incomplete JSON
          {:noreply, state2} =
            EventStream.handle_info(
              {:chunk, ~s({"type":"init","data":{"isPrimary")},
              state
            )

          # Should have buffered the incomplete line
          assert state2.buffer == ~s({"type":"init","data":{"isPrimary")

          # Second chunk - completes the JSON
          {:noreply, state3} =
            EventStream.handle_info(
              {:chunk, ~s(:true,"hostname":"node1"}}\n)},
              state2
            )

          assert state3.buffer == ""
        end)

      assert log =~ "init event"
      assert log =~ "primary"
    end

    test "handles init event without hostname field (primary node)" do
      log =
        capture_log([level: :debug], fn ->
          state = make_state(:no_hostname)

          {:noreply, _state} =
            EventStream.handle_info(
              {:chunk, ~s({"type":"init","data":{"isPrimary":true}}\n)},
              state
            )
        end)

      assert log =~ "init event"
      assert log =~ "primary"
      assert log =~ "hostname="
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
