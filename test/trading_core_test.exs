defmodule TradingCoreTest do
  use ExUnit.Case, async: true

  describe "version/0" do
    test "returns a non-empty string" do
      assert is_binary(TradingCore.version())
      assert TradingCore.version() != ""
    end

    test "matches a real commit reachable from this checkout's history" do
      # Deliberately NOT asserting version/0 == current `git rev-parse
      # HEAD` — @git_sha is captured once at compile time (see this
      # module's own moduledoc for why that's deliberate), so it's
      # expected to lag one or more commits behind HEAD by however long
      # it's been since the last recompile (this is normal: edit code,
      # test, commit — the compiled artifact is always at least one
      # commit behind by the time a commit lands). What actually matters
      # is that it's a real commit that exists in this repo's history,
      # not a stubbed/fixed placeholder value — `git cat-file -e` raises
      # (a non-zero exit via `System.cmd/3`'s default `:into` behavior
      # returning a non-{_, 0} tuple below) if the SHA doesn't resolve to
      # a real object at all.
      assert {_output, 0} =
               System.cmd("git", ["cat-file", "-e", TradingCore.version()], cd: File.cwd!())
    end

    test "looks like a full git SHA (40 hex characters), not a shortened one" do
      assert String.match?(TradingCore.version(), ~r/^[0-9a-f]{40}$/)
    end

    test "is a compile-time constant — stable across repeated calls in the same run" do
      assert TradingCore.version() == TradingCore.version()
    end
  end
end
