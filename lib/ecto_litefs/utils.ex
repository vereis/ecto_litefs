defmodule EctoLiteFS.Utils do
  @moduledoc """
  Shared utility functions.
  """

  import Bitwise

  @doc """
  Returns exponential backoff delay with jitter.

  Calculates `base_delay * 2^retry_count`, capped at `max_delay`, with
  random jitter to prevent thundering herd problems.

  ## Options

  * `:base_delay` - Base delay in ms (default: 100)
  * `:max_delay` - Max delay cap in ms (default: 30_000)
  * `:jitter` - Jitter factor 0.0-1.0 (default: 0.5)
  """
  @spec backoff_delay(non_neg_integer(), keyword()) :: pos_integer()
  def backoff_delay(retry_count, opts \\ []) do
    base_delay = Keyword.get(opts, :base_delay, 100)
    max_delay = Keyword.get(opts, :max_delay, 30_000)
    jitter_factor = Keyword.get(opts, :jitter, 0.5)

    exponential_delay = base_delay * (1 <<< retry_count)
    capped_delay = min(exponential_delay, max_delay)
    jitter = trunc(capped_delay * jitter_factor * :rand.uniform())

    capped_delay + jitter
  end
end
