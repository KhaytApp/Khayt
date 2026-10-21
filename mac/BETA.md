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
   **Live since alpha.64 (11 October 2026).** The week of reports can be read
   from 18 October.
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

   - **Sorting a real linked drive** (alpha.66 to alpha.68): "Sort linked
     folders…" on the shop's Google Drive, with the assistant on and off,
     ending with Apply. Then: the prints look right, pictures sit on the right
     prints, and a group the shop made by hand has not moved.
   - **Check pictures** (alpha.68) with the shop's own AI provider: a "yes"
     puts the picture on, a "no" is not offered again.
   - **Shortcuts and Siri** (alpha.69): "What is printing" and "What is
     waiting to print" appear in the Shortcuts app and answer.
   - **The iPhone over the shop's Wi-Fi** (alpha.68 and alpha.69): a WhatsApp
     update logged on the customer, and a large model sent while the Mac is
     busy.

   Add to this list whatever later alphas ship without being tried, and strike
   each item when it is done.
4. **The not-yet-built list in `mac/README.md` is empty or deliberately
   deferred.** Its one item, moving a job on when its print starts or ends,
   is either built or written down as "after beta".
   **Done, 14 October 2026:** deferred until after beta.1, and written so in
   the list.
5. **Big refactors land before the week in (2), not during it.** The split of
   `Shop.swift` is the one planned. A soak week that ends with a refactor
   has not soaked the build that ships.
   **Done, 11 October 2026:** the split landed in #1822, after alpha.64.
6. **The usual pre-release review is clean** (bugs, security, and the UI in
   English and Arabic, light and dark) over everything since the last alpha.

## How beta.1 was actually decided (21 October 2026)

Not every box above was ticked. The owner decided to release `4.0.0-beta.1`
after alpha.86, on one condition: ten comprehensive reviews of the whole app
(security twice, money, jobs and printers, stock, library, data integrity and
crashes, customers, and the interface in English and in Arabic, light and
dark), each fix checked by a second and third independent pass, until all ten
areas came back clean.

- Criterion 1 (crash reports read): met in spirit, and the review found why it
  was weak. Only one install reports, and before alpha.86 a Swift crash was
  never sent. The one shipped-app crash (alpha.77, Settings ▸ Overhead) was
  found in the Mac's own crash logs and had already been fixed by #1911.
  alpha.86 reports Swift crashes through MetricKit.
- Criterion 2 (a week on the real book): NOT met. The shop's book still holds
  no orders. Waived by the owner.
- Criterion 3 (the untried list): NOT met. Waived by the owner. The list
  stands as the first thing to try on the beta.
- Criteria 4, 5 and 6: met. The review is the beta.1 batch PR.

Deferred from the review, on purpose: the catalogue ignoring a part's
quantity in its cost (fixing it re-prices existing products, so it is the
owner's call), the dashboard's gross margin counting shipping, the custom
report mixing price terms, launch-time file checks on the main thread for a
NAS library, Spotlight's rebuild cost, and the 3MF multi-component re-read.

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
