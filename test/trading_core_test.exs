defmodule TradingCoreTest do
  use ExUnit.Case, async: true

  describe "version/0" do
    test "returns a non-empty string" do
      assert is_binary(TradingCore.version())
      assert TradingCore.version() != ""
    end

    test "matches this checkout's actual current git HEAD" do
      # Confirms version/0 is reading the real repo, not a stubbed/fixed
      # value — if this ever drifts, either the compile-time capture
      # broke, or (more likely) this test is running against a stale
      # compiled artifact from a different commit than the working tree
      # currently sits at.
      {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: File.cwd!())
      assert TradingCore.version() == String.trim(sha)
    end

    test "looks like a full git SHA (40 hex characters), not a shortened one" do
      assert String.match?(TradingCore.version(), ~r/^[0-9a-f]{40}$/)
    end

    test "is a compile-time constant — stable across repeated calls in the same run" do
      assert TradingCore.version() == TradingCore.version()
    end
  end
end
