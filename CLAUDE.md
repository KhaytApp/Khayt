# CLAUDE.md

Notes for agents working in this repository. [CONTRIBUTING.md](./CONTRIBUTING.md) covers the
human workflow (setup, sign-off, code areas); this file covers what the repo *enforces*, which
is the part that silently wastes a session if you don't know it.

## `main` is protected — and it is a ruleset, not classic branch protection

`gh api repos/KhaytApp/Khayt/branches/main/protection` returns **404 Branch not protected**.
That is not the answer: protection lives in a **repository ruleset** named `Protect main`
(id `16949689`, enforcement `active`, targeting `~DEFAULT_BRANCH`). Read the rules that
actually apply with:

```bash
gh api repos/KhaytApp/Khayt/rules/branches/main
```

Rules in force:

| Rule | Effect |
|---|---|
| `deletion` | `main` cannot be deleted |
| `non_fast_forward` | no force-push to `main` |
| `required_status_checks` (**strict**) | the required checks must pass **and** the branch must be up to date |

Required checks — all come from [`.github/workflows/ci.yml`](.github/workflows/ci.yml):

- `Changelog entry`
- `Syntax check`
- `E2E smoke (Electron)`
- `DCO sign-off`
- `Mac app tests`

There are **five**, and this list said four for long enough to be worth a warning: `Mac app
tests` was required all along and simply went unrecorded here, so a session that trusted the
list read a red Swift check as advisory and went looking for why its PR would not merge.
Read the ruleset, not this file, when the two disagree — the command is three lines up.

`Mac app tests` is the one that surprises a JavaScript-only session, because it is **not**
path-filtered: a PR touching nothing but `lib/` still has to satisfy it. It runs `swift
build`, `swift test` and the guard that `mac/KhaytCore/Sources/KhaytCore/JS/` has not drifted
from `lib/`. **161** modules are copied into that bundle, and **24** of them are pinned
harder still — `KhaytCoreTests` loads the real file out of `lib/` and asserts the Swift agrees
with it, so the JavaScript is the fixture (see `Tests/KhaytCoreTests/Parity.swift`). Change
one of those and the check that blocks your merge is a Swift one. Run it before pushing:

```bash
bash mac/sync-js.sh && swift test --package-path mac/KhaytCore
```

`bypass_actors` is **empty**, so nobody is exempt. `gh pr merge --admin` is refused with
`Repository rule violations found` even for a repo admin — verified by attempting it, not
inferred from config. Rulesets have no "include administrators" toggle: exemption exists only
if a principal is explicitly listed, and none is.

### What this means in practice

- **Never `git checkout -b` from wherever HEAD happens to be.** Branch explicitly:
  ```bash
  git fetch origin main && git checkout -B <branch> origin/main
  ```
  Worktrees here sit on long-lived session branches that can be dozens of commits behind
  `main`. A PR opened from a stale base is `mergeStateStatus=BEHIND` and cannot merge under
  the strict rule, so the mistake surfaces only at merge time.
- **Direct pushes to `main` are effectively blocked** — required checks cannot have run on a
  commit that has not been pushed. Everything lands by PR. Release *tags* are unaffected, so
  the `vX.Y.Z` tagging flow in [VERSIONING.md](./VERSIONING.md) still works.
- **`gh pr merge --auto` does not work here.** Auto-merge is switched off at the repository
  level, so the flag fails outright:

  ```
  GraphQL: Auto merge is not allowed for this repository (enablePullRequestAutoMerge)
  ```

  Confirmed with `gh api repos/KhaytApp/Khayt --jq .allow_auto_merge` → `false`, after the
  flag was tried and refused. Wait for green and merge yourself:

  ```bash
  gh pr checks <n> --watch && gh pr merge <n> --squash --delete-branch
  ```

  `--delete-branch` is worth passing every time: `delete_branch_on_merge` is also `false`, so
  nothing tidies up on its own.
- **When `main` moves under an open PR**, bring the branch up to date yourself and let CI
  rerun — the merge is refused until it is current. GitHub's **Update branch** button is not
  available either (`allow_update_branch` is `false`), so it is `git rebase origin/main` (or
  `git merge origin/main`) and a push. Expect this: with checks taking ~5 minutes and `main`
  moving several times an hour, a PR can go `BEHIND` *while its own checks are running*.

### Deliberately *not* required: `iOS contract`

`.github/workflows/ios-contract.yml` is path-filtered to `ios/**`, `lib/lan-server.js` and
`scripts/ios-contract-*`. On a PR touching none of those the workflow never runs, so the check
never reports — and a required check that never reports blocks the PR forever. Leave it out
unless the filters are removed. The required checks all live in `ci.yml`, which has no path
filters and therefore always reports.

## Sign-off is enforced — commit with `-s`

Every non-merge commit in a PR must carry a `Signed-off-by` trailer whose email matches its own
author, or `DCO sign-off` fails. Use `git commit -s`; to fix a branch after the fact,
`git rebase --signoff origin/main`.

The email has to be the **author's**, because the DCO is the author certifying their own work.
The usual real-world failure is a commit made in the GitHub web UI, which authors as
`…@users.noreply.github.com` while local `git config` says something else — the guard prints
both addresses when they disagree, rather than just refusing.

Merge commits are exempt on purpose: `main` is strict, so a stale PR gets an "Update branch"
merge commit written by GitHub that nobody can sign. See [`scripts/check-dco.js`](scripts/check-dco.js).

## `KhaytCore` is shared with the phone now — it is not a Mac-only package

This is the one thing in this repo that is easy to break from the outside and
impossible to notice from inside a Mac session.

`mac/KhaytCore` builds for **macOS and iOS**. `ios/KhaytCompanion` links the
`KhaytCore` product and computes the shop's money with it, which is the whole
reason there is no second tax engine written in Swift. The path is not obvious
from the directory name: a package under `mac/` ships inside the iPhone app.

**Four things silently un-ship the phone.** None of them fails a Mac build, and
`swift build` in `mac/KhaytCore` will look perfectly green for all four:

| Change | What it does to the phone |
|---|---|
| `import AppKit` / `Cocoa` / any macOS-only framework in `Sources/KhaytCore/` | the iOS build stops compiling |
| dropping `.iOS("26.0")` from `platforms:` in `Package.swift` | the companion cannot resolve the package at all |
| moving a file **out** of `Sources/KhaytCore/` into `Sources/KhaytApp/` | the phone loses the type; `StoreWriter` is the live example — the phone writes its book through it |
| a macOS-only API inside an otherwise portable file | compiles here, fails against the iOS SDK |

`KhaytCoreIsPortableTests` in `KhaytCoreTests` catches the first two in the
ordinary Mac test run, so `swift test` is enough to be told. It cannot catch the
last one, because only a compiler with the iOS SDK can — for that, build it:

```bash
xcodebuild -scheme KhaytCore -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/kc-ios build          # from mac/KhaytCore
```

`.github/workflows/ios-contract.yml` runs that on CI and its path filter now
includes `mac/KhaytCore/**`, so a Mac-side change that breaks the phone reports
on the PR that made it. It is still **not** a required check — see the section
above for why a path-filtered check must stay optional.

**Moving logic out of JavaScript into Swift is the common case here, and it is
fine** — that is what the `Mac: work out X natively` commits do. Put the Swift in
`Sources/KhaytCore/`, not `Sources/KhaytApp/`, unless it genuinely needs AppKit.
A rule that lands in `KhaytApp` is a rule the phone has to ask the Mac for.
