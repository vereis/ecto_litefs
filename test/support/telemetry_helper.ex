defmodule EctoLiteFS.Test.TelemetryHelper do
  @moduledoc """
  Helper module for testing telemetry events.
  """

  @doc """
  Attaches a telemetry handler that sends events to the given pid.

  Returns a unique reference that can be used to match received messages
  and to detach the handler.

  ## Example

      ref = TelemetryHelper.attach_event_handlers(self(), [[:my_app, :event]])
      # trigger event
      assert_receive {[:my_app, :event], ^ref, measurements, metadata}
      :telemetry.detach(ref)
  """
  def attach_event_handlers(pid, event_names) do
    ref = make_ref()

    handler_function = fn event_name, measurements, metadata, _ ->
      send(pid, {event_name, ref, measurements, metadata})
    end

    :telemetry.attach_many(
      ref,
      event_names,
      handler_function,
      nil
    )

    ref
  end
end
