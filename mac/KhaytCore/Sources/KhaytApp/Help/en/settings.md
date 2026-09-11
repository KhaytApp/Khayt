# Settings

⌘, opens them. They are written through the same rules Khayt for Windows and
Linux saves through, so a setting changed here means the same thing there.

## What is worth setting first

- **Your shop's details** — name, address, contact, commercial registration and
  VAT number. These go on every invoice.
- **Currency** — what every figure in the app is in.
- **Tax** — whether VAT is charged, at what rate, and whether ZATCA's
  requirements apply.
- **Language** — Khayt's own interface language. Arabic lays the whole app out
  right to left.
- **Catalogue languages** — which languages your products are written in. This
  is what decides the tabs in the product editor.
- **Default margin** — what a price is computed at when a product does not set
  its own.
- **Working week** — which days the shop is open, which every lead time and
  capacity figure is counted against.

## The interface language is the shop's, not the Mac's

Khayt follows what you set here rather than what the Mac is set to. A Riyadh
shop on an English Mac keeps its book in Arabic, and that is the case this rule
exists for.

Changing it relaunches the app, because the writing direction has to be settled
before the window is built.

## Secrets

Printer keys, the cloud token and storage credentials are kept in the Mac's
Keychain, not in the book. The first time the app reads one, macOS asks — that
prompt is the system's, and saying no simply leaves those fields sealed while
everything else opens normally.
