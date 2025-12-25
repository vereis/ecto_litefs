defmodule EctoLiteFS.Assertions do
  @moduledoc """
  Custom assertions for testing async/polling behavior.
  """

  @doc """
  Asserts that a condition becomes true within a timeout period.

  Retries the assertion at a fixed interval. Useful for testing
  async GenServer behavior or polling-based state changes.

  ## Options

  * `:timeout` - Total time to wait in milliseconds (default: 1000)
  * `:interval` - Initial retry interval in milliseconds (default: 10)

  ## Examples

      # Simple boolean condition
      eventually(fn -> Process.alive?(pid) end)

      # With pattern matching assertion
      eventually(fn ->
        assert EctoLiteFS.tracker_ready?(:my_instance)
      end)

      # Custom timeout
      eventually(fn -> table_exists?("my_table") end, timeout: 5000)

  """
  def eventually(fun, opts \\ []) when is_function(fun, 0) do
    timeout = Keyword.get(opts, :timeout, 1000)
    interval = Keyword.get(opts, :interval, 10)
    deadline = System.monotonic_time(:millisecond) + timeout

    do_eventually(fun, interval, deadline)
  end

  defp do_eventually(fun, interval, deadline) do
    fun.()
  rescue
    e ->
      now = System.monotonic_time(:millisecond)

      if now >= deadline do
        reraise e, __STACKTRACE__
      else
        Process.sleep(interval)
        do_eventually(fun, interval, deadline)
      end
  end
end
