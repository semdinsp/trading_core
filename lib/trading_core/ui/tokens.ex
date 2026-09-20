defmodule TradingCore.UI.Tokens do
  @moduledoc """
  Domain value → daisyUI/Tailwind class string. Pure string transforms,
  one per badge-able concept, shared so two apps cannot disagree about
  what a colour *means*.

  ## Why this is in `trading_core`, and what it must never become

  `trading_core` takes no Phoenix, no Ecto, no side effects. This module
  honours that: it returns **strings, never `~H` components**, so it is
  the same kind of pure computation as everything else here. That
  boundary is the entire reason a UI concern can live in this library at
  all. If a caller finds itself wanting `attr`, `~H`, or
  `Phoenix.Component`, that belongs in a separate markup library — do not
  add `phoenix`/`phoenix_live_view` to this app's deps to make it fit.

  It lives here rather than in a new `trading_ui` repo because
  `trading_core` is already a path dependency of both consumers (and four
  other apps), so sharing costs zero release ceremony — no new repo, no
  tag, no eight-app version bump. Every app in this workspace is its own
  git repo, which makes a published shared library expensive: a change
  costs a PR, a tag, eight dependency bumps, eight CI runs, eight
  deploys. That price is worth paying for a colour that is being misread
  on a trading screen; it is not worth paying for markup.

  ## The bug this exists to prevent

  `trading_system` and `trading_options_sim` each rendered a lifecycle
  badge from its own private colour function, and they disagreed on three
  of the five stages — `test_portfolio` was amber in one app and green in
  the other, and `quarantine` (the stage meaning *this strategy is under
  suspicion*) was amber in one and brand-primary in the other. The same
  operator reads both screens.

  The two functions also disagreed *structurally*: one enumerated
  `discovery`/`retired` and fell through for the rest, the other fell
  through for a different subset. Each fallback quietly absorbed a
  different set of stages, which is how the two drifted without anyone
  noticing.

  So every stage here is enumerated explicitly and there is **no
  catch-all clause**. An unrecognised stage raises `FunctionClauseError`
  rather than rendering a neutral grey badge — a loud failure in test
  beats a silently wrong colour in production, and a fallback is
  precisely the mechanism that allowed the original divergence.

  The class strings are the ones the apps already render. This module
  codifies an existing agreement; it does not redesign anything. All
  eight apps already share the `dark_pool` daisyUI theme, with
  byte-identical `--color-*` declarations, so the shared visual language
  exists already — it was just enforced by copy-paste. This gives one
  slice of it a home.

  The accompanying tests assert every exact string, and are the actual
  contract: they make a colour change in one app a failing build rather
  than a silent divergence, the same way `TradingContract.Topics`' tests
  do for topic strings.
  """

  @doc """
  Badge classes for a strategy version's lifecycle stage.

  Raises `FunctionClauseError` on an unknown stage — see this module's
  own moduledoc for why there is deliberately no fallback clause.

  Three of these reconcile a prior disagreement between the two consuming
  apps rather than matching either one exactly:

    * `quarantine` is `warning`. Amber is this workspace's established
      "needs attention" signal and quarantine means exactly that;
      `trading_system`'s previous `primary` read as a brand accent, not a
      warning.
    * `test_portfolio` is `primary`. The stage is neither a warning nor a
      success — it is "actively being trialled", which is what the brand
      accent is for. It also frees amber to mean only `quarantine`, so
      the two stop competing.
    * `live` is `success`. Both apps previously fell through to a neutral
      grey, which left the most important stage the least visible. This
      is the one genuine improvement in the set, and it is safe precisely
      because neither app had chosen a colour for it deliberately.

  `discovery` and `retired` take the neutral outlines both apps already
  used, keeping `trading_options_sim`'s more-recessive explicit `retired`
  value — a retired version should fade back further than a discovery
  one.
  """
  @spec lifecycle_stage(String.t()) :: String.t()
  def lifecycle_stage(stage) when is_binary(stage), do: do_lifecycle_stage(stage)

  defp do_lifecycle_stage("discovery"), do: "border-base-content/20 text-base-content/70"
  defp do_lifecycle_stage("quarantine"), do: "border-warning/40 text-warning bg-warning/10"
  defp do_lifecycle_stage("test_portfolio"), do: "border-primary/40 text-primary bg-primary/10"
  defp do_lifecycle_stage("live"), do: "border-success/40 text-success bg-success/10"
  defp do_lifecycle_stage("retired"), do: "border-base-content/15 text-base-content/40"

  @doc """
  Badge classes for a position or strategy direction.

  `long`/`short` are this workspace's own theme colours (`--color-long`,
  `--color-short` in every app's `app.css`), not daisyUI semantic ones —
  green and red respectively, independent of `success`/`error` so a
  direction badge never reads as a status.

  Raises `FunctionClauseError` on an unknown direction, same reasoning as
  `lifecycle_stage/1`.
  """
  @spec direction(String.t()) :: String.t()
  def direction(direction) when is_binary(direction), do: do_direction(direction)

  defp do_direction("long"), do: "border-long/40 text-long bg-long/10"
  defp do_direction("short"), do: "border-short/40 text-short bg-short/10"
end
