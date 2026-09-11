# When something is wrong

## "Opened read-only"

Khayt for Windows and Linux has the book open, or another Mac does. One app
writes a book at a time, deliberately: two writing at once is how an afternoon's
work disappears. Close it there and use **Book → Reload**.

## A figure here disagrees with the other app

It should not — both compute from the same shared rules. Two things make it look
as though they disagree:

- **The books are different.** Check the name in the top-left; a development
  book and a shipped one are two different files.
- **One is stale.** **Book → Reload** after the other app has written.

If it still disagrees, that is worth reporting, with both figures.

## The printer says nothing

- Check the address and the key with **Test** on the machine.
- A printer that moved to a new address is usually followed automatically, but
  only once Khayt has seen its serial number — a printer it has never reached
  cannot be recognised later.
- Bambu printers report status only. Remote control needs Bambu's own connector.

## A model will not import

- It may already be there. Khayt recognises a file by its contents, not its
  name, and refuses a duplicate.
- Only model and G-code files are taken; everything else in a folder is passed
  over.
- Importing your own library folder into itself does nothing, on purpose.

## An invoice looks unstyled

That was a real fault in 4.0.0-alpha.1 and alpha.2, fixed in alpha.3. If you are
on an alpha older than that, update — those builds could not launch at all on a
Mac that had not built them, so you are most likely already past it.

## Getting a build that works

**Khayt → Check for Updates…**. If the app will not start at all, no update can
reach you — Sparkle runs inside the app — and the build has to be downloaded by
hand from the releases page.
