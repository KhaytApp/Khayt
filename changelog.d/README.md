# Changelog fragments

A change a shop can notice gets one file here, named after your branch with
`/` turned into `-`: `changelog.d/<your-branch>.md`. Do not add the line to
`CHANGELOG.md` itself. Every open pull request used to add its line at the top
of `[Unreleased]`, so each merge put every other open pull request in conflict.

Write exactly what you would have added under `[Unreleased]`:

```markdown
- **Bed Ready: the converter keeps a plate's colours.** One or two sentences a shop can read.
```

- Use one or more lines that start with `- `. A continuation line is indented by two spaces.
  Blank lines are fine.
- Do not use headings. A `### Before you update` item still goes in `CHANGELOG.md` itself,
  because the updater reads it there.
- The "Changelog entry" check accepts a fragment your pull request **added**. Editing or
  renaming someone else's fragment doesn't count as your entry. Removing one is refused,
  because only the cut removes fragments. A fragment the cut could not fold is refused too.
- A release pull request (a new `## [X.Y.Z]` section, or a version bump) is refused while
  any fragment is still here, so a late entry can't miss the release it shipped in.
- At the release cut, `npm run changelog:fold` moves every fragment to the top of
  `[Unreleased]`, newest first, and deletes the files (VERSIONING.md, step 0). The cut refuses
  to tag while a fragment is still waiting.
