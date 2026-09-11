# Cloud sync

Khayt Cloud carries your book between machines and gives your customers a page
to follow their order on. It is optional: the app works completely without it.

## What this app does

- **Check** — compares your book against the cloud and says what differs,
  without sending anything. Read-only, so it is safe to run when you are not
  sure.
- **Send** — pushes your book up.
- **Pull** — brings the cloud's copy down and merges it.

## Your secrets do not leave

The book holds the cloud token, the printer API keys and any storage secrets.
Before anything is sent, those are taken out and replaced with masks. The copy
that leaves never contains them.

## Locking

**Book → Lock cloud** ends automatic sync and forgets the key held in memory.
It is the way back out, and the only one — worth knowing if you are leaving a
Mac somewhere you do not control.

## Two machines

If two machines both keep this book, update them both before relying on a sync.
An older build can carry fields a newer one has changed, and whichever wrote
last wins — so a machine left behind on an old version can quietly put old
values back.
