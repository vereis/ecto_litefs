defmodule EctoLiteFS.RPC do
  @moduledoc """
  Wrapper around :erpc for testability.

  In production, this delegates to :erpc.call/4.
  In tests, this can be mocked with Mimic.
  """

  @doc """
  Executes a function on a remote node via :erpc.

  ## Parameters
    - node: The remote node to execute on
    - fun: The function to execute
    - timeout: Timeout in milliseconds

  ## Returns
    - The result of the function execution
    - Raises :erpc exceptions on timeout, noconnection, etc.
  """
  @spec call(node(), (-> term()), pos_integer()) :: term()
  def call(node, fun, timeout) do
    :erpc.call(node, fun, timeout)
  end
end
