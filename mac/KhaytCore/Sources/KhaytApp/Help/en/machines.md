# Machines and printers

What you print on, and — when you connect one — what it is doing right now.

## Adding a machine

A machine is a record: its name, what kind it is, its bed size, what it cost and
what it costs to run. Those last two are what let Khayt tell you what an hour on
that machine is worth.

## Connecting to a printer

A machine can be linked to the printer itself. Khayt speaks seven protocols:

- **Moonraker / Klipper** — including the Snapmaker U1.
- **OctoPrint**
- **PrusaLink**
- **Duet**
- **Repetier**
- **Bambu** — status only. Bambu now requires their own connector for remote
  control.
- **Elegoo resin (SDCP)**

Enter the address and the key, press **Test**, and Khayt says what answered. The
key is sealed in the Mac's Keychain, not written into the book.

## Live status

A connected printer shows what it is printing, how far through it is, the
temperatures, and how long is left.

Two things worth knowing about that reading:

- **Progress is by layer, not by bytes** where the printer will say. A byte
  position through a file is not a measure of work — a 31 MB model read 0.7%
  done when it was nearly 20% done.
- **The time left is the slicer's estimate** when the file carries one, and only
  extrapolated when it does not.

## A printer that moved

Printers get new addresses when a router restarts. Khayt recognises a machine it
has seen before by its board's own serial number and follows it to the new
address, rather than showing it as offline.

## Dropping one object from a plate

On a Klipper or Moonraker printer, a single object on a plate can be skipped
while the rest of the plate carries on — for the one part that has come loose.

**It cannot be undone.** Klipper does not reprint the layers skipped while an
object was dropped, so an object dropped by mistake is scrap.
