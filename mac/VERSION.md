# The Mac app's version, and why it is not `package.json`'s

`mac/version.json` is the ONLY source of the native Mac app's version. It is
deliberately not read from `package.json`, which numbers the Electron app: those
two products ship on their own schedules now, and a Mac build that called itself
`3.7.0` because that is what Electron happened to be on would be lying about
which app it is.

```json
{ "version": "4.0.0-alpha.1", "build": 1 }
```

## Two fields, and Sparkle needs both

| | Info.plist key | What it is |
|---|---|---|
| `version` | `CFBundleShortVersionString` | the name people say — `4.0.0-alpha.1` |
| `build`   | `CFBundleVersion`            | an integer that ONLY ever goes up |

**`build` is not decoration and it is not derived.** Sparkle decides whether an
update exists by comparing `CFBundleVersion`, and `CFBundleVersion` must be
digits and dots — so `4.0.0-alpha.1` cannot be it. The obvious fix is to strip
the suffix, which is what this build did before Sparkle existed:

    4.0.0-alpha.1  → 4.0.0
    4.0.0-alpha.2  → 4.0.0      ← the same number

Two consecutive alphas would have carried the SAME `CFBundleVersion`, and
Sparkle would have told every tester they were up to date. The failure is
silent on both sides: the build is fine, the feed is fine, and nobody updates.

So `build` is its own integer and every published build increments it, whatever
the marketing string does.

## Bumping it

```bash
node scripts/bump-mac-version.js 4.0.0-alpha.2   # sets version, build += 1
node scripts/bump-mac-version.js --build         # build += 1, version unchanged
```

`test/mac-version.test.js` refuses a version that is not semver, a build that is
not a positive integer, and a build that did not increase against the newest
release already published in `KhaytApp/khayt-mac`.
