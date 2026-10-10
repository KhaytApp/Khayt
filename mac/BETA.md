# Khayt for macOS: what has to be true before 4.0.0-beta.1

The native app has shipped sixty-three alphas. An alpha with no finish line
makes every release feel urgent and none of them final, so this is the finish
line. It was agreed in October 2026. Each item below is checked against what
happened, not against a plan.

When every box is ticked, the next cut is `4.0.0-beta.1` instead of
`4.0.0-alpha.N`.

## The criteria

1. **Crash reports are live, and they have been read.** The opt-in crash
   reports and usage counts (issue #1789) are in a published alpha. A week of
   what came in has been read, and no crash in it is unexplained. Before this
   exists, a crash in the field is a crash nobody hears about. That is the
   reason it comes first.
2. **A week on the real book.** The shop runs its own orders, spools and money
   on the Mac for seven days in a row: not the sample shop, and not the empty
   book. Nothing is lost, and no figure is wrong. A bug found here resets the
   week once it is fixed.
3. **What was shipped untried has been tried.** At alpha.63 these were:
   - The iPhone's Live Activity updates, sent through the real Khayt Cloud to
     a real iPhone, with the phone locked. Includes the "no phone is
     listening" quiet period.
   - **Add as supplier** from a receipt, end to end on a real book. Afterwards,
     a second receipt from the same seller is matched to that supplier.
   - Settings ▸ Integrations, seen in English and Arabic, light and dark.

   Add to this list whatever later alphas ship without being tried, and strike
   each item when it is done.
4. **The not-yet-built list in `mac/README.md` is empty or deliberately
   deferred.** Its one item, moving a job on when its print starts or ends,
   is either built or written down as "after beta".
5. **Big refactors land before the week in (2), not during it.** The split of
   `Shop.swift` is the one planned. A soak week that ends with a refactor
   has not soaked the build that ships.
6. **The usual pre-release review is clean** (bugs, security, and the UI in
   English and Arabic, light and dark) over everything since the last alpha.

## What changes at beta

- **The Electron lane turns `BUILD_MAC` off.** Until now the Electron app has
  kept a macOS build for shops not on the native app (VERSIONING.md). Tell
  that session when `4.0.0-beta.1` is published, not when it is merged.
- **One feed, as before.** The Mac has a single Sparkle feed, and a beta is
  still published as a pre-release (`./mac/release-local.sh`, no `--final`).
  Nothing changes for installs: they update to the beta as they did to each
  alpha.
- **Fewer cuts.** A beta is cut when something must reach the shop, as now.
  Each cut also has to keep criteria 1 and 2 true: no unexplained crash in
  the reports, and nothing lost or wrong on the real book.
