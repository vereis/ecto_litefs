defmodule EctoLiteFS.UtilsTest do
  use ExUnit.Case, async: true

  alias EctoLiteFS.Utils

  describe "backoff_delay/2" do
    test "returns delay in expected range with default options" do
      delay = Utils.backoff_delay(0)
      assert delay >= 100 and delay <= 150

      delay = Utils.backoff_delay(1)
      assert delay >= 200 and delay <= 300

      delay = Utils.backoff_delay(2)
      assert delay >= 400 and delay <= 600

      delay = Utils.backoff_delay(3)
      assert delay >= 800 and delay <= 1200
    end

    test "respects custom base_delay option" do
      delay = Utils.backoff_delay(0, base_delay: 200)
      assert delay >= 200 and delay <= 300

      delay = Utils.backoff_delay(2, base_delay: 200)
      assert delay >= 800 and delay <= 1200
    end

    test "enforces max_delay cap" do
      delay = Utils.backoff_delay(10, max_delay: 5_000)
      assert delay >= 5_000 and delay <= 7_500

      delay = Utils.backoff_delay(20, max_delay: 5_000)
      assert delay >= 5_000 and delay <= 7_500
    end

    test "respects custom jitter factor" do
      delay = Utils.backoff_delay(2, jitter: 1.0)
      assert delay >= 400 and delay <= 800
    end

    test "zero jitter produces deterministic results" do
      delays = for _ <- 1..10, do: Utils.backoff_delay(2, jitter: 0.0)
      assert Enum.uniq(delays) == [400]
    end

    test "returns minimum delay for retry count 0" do
      delay = Utils.backoff_delay(0)
      assert delay >= 100 and delay <= 150
    end

    test "jitter adds randomness" do
      delays = for _ <- 1..20, do: Utils.backoff_delay(3)
      assert length(Enum.uniq(delays)) > 1
    end

    test "delay is always within bounds" do
      for retry_count <- 0..10 do
        delay = Utils.backoff_delay(retry_count)
        base_delay = 100
        max_delay = 30_000
        jitter_factor = 0.5

        exponential = base_delay * :math.pow(2, retry_count)
        capped = min(trunc(exponential), max_delay)
        max_jitter = trunc(capped * jitter_factor)

        assert delay >= capped and delay <= capped + max_jitter
      end
    end

    test "handles large retry counts" do
      delay = Utils.backoff_delay(100)
      assert delay >= 30_000 and delay <= 45_000
    end

    test "works with all options combined" do
      delay = Utils.backoff_delay(3, base_delay: 50, max_delay: 1_000, jitter: 0.3)
      assert delay >= 400 and delay <= 520
    end
  end
end
