defmodule TradingCore do
  @moduledoc """
  Top-level identity for this library — today, just `version/0`.

  `trading_core` has no meaningful release version of its own: it's
  consumed exclusively as a `path:` dependency by sibling apps in this
  monorepo (`trading_signal`, `trading_system`, `trading_backtest`, ...),
  never published or tagged as a Hex package, and its `mix.exs` `version`
  field has sat at `"0.1.0"` since the app was first scaffolded — through
  every commit since, including the entire `TradingCore.Signal.Compute`
  extraction this function exists to let a caller detect changes to.
  Exposing that field verbatim would answer "what does mix.exs say,"
  which is not the same question as "did the signal math actually
  change" — see `version/0`'s own doc for what this returns instead.
  """

  # Captured once, at compile time, not read fresh on every call —
  # trading_core's own source tree (and therefore its own git history)
  # doesn't move while the BEAM is running, so there's nothing to gain
  # from re-running `git rev-parse` on every call, only cost.
  #
  # `cd: __DIR__` runs this from trading_core's own lib/ directory,
  # regardless of which sibling app (trading_signal, trading_backtest,
  # ...) actually triggered this compile as a path: dependency — git
  # walks up from there to trading_core's own .git, never a caller's.
  @git_sha (case System.cmd("git", ["rev-parse", "HEAD"], cd: __DIR__, stderr_to_stdout: true) do
              {sha, 0} -> String.trim(sha)
              _failure -> "unknown"
            end)

  @doc """
  `trading_core`'s own git commit SHA, captured once at compile time —
  the actual signal for "did the code that computes signal values
  change," since every real change to `TradingCore.Signal.Compute`/
  `TradingCore.Signals`/etc. is a new commit, unlike `mix.exs`'s own
  `version` field (see this module's own moduledoc for why that's not
  used instead).

  `trading_backtest` is the intended caller: record this alongside every
  evaluation row it writes, so a later comparison against the *current*
  `TradingCore.version/0` can tell "this stored result was computed
  against code that has since changed" (a stale result, needing a
  re-evaluation) apart from "this result is still valid" (an unchanged
  `version/0`) — without either app needing to reason about *what*
  changed, only *whether* anything did.

  Returns `"unknown"` if `git rev-parse` itself failed at compile time
  (no `.git` present at all — e.g. a build from a source tarball with no
  git history, rather than a clone) — a caller comparing against
  `"unknown"` should treat it as "can't establish freshness," not
  silently equal to a previous `"unknown"` from a different, also
  gitless build; two unrelated builds both failing to find git history
  are not evidence they're the same code.
  """
  @spec version() :: String.t()
  def version, do: @git_sha
end
