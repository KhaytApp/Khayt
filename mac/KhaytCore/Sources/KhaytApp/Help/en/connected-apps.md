# Connected apps

Slicers that send sliced files straight to this Mac, and what to do when pairing doesn't work.

## Before you start

- Khayt for Mac. Pairing a slicer is not in the Windows or Linux app.
- The LAN server on, with **Listen on all network interfaces (LAN)** turned on, in Settings → Online. Off, the Mac answers only itself and no slicer can reach it.
- OrcaSlicer 2.5.1 or later with the Khayt plugin installed, on a computer on the same network as the Mac.
- You are the shop's owner or a manager. Others can't pair or remove a slicer.

## Pair a slicer

- Open **Connected apps** in the sidebar, under Floor, and click **Pair a slicer**. For the next two minutes a slicer on your network may ask to pair, and the Mac shows the address to type.
- In OrcaSlicer, open Khayt → Pair → On this network and type that address exactly.
- The Mac asks **Approve "name"?** and says which app asked and from which address. Check that this is your slicer.
- Both screens now show a 6-digit number. If the two numbers are the same, click **Numbers match — approve**. The slicer appears under Paired slicers.

## If the numbers are different, deny

Click **Deny**. Different numbers mean the request did not come straight from your slicer, so something else on the network may be in between. Don't approve it to see what happens. Check that the slicer is on your own network and pair again. One click of Pair a slicer allows three tries.

## What a paired slicer can and can't see

It may send files to the From slicer inbox and see the job queue: job numbers, stages and machines only, never titles or customers. It also sees your machines, the shop's name, and how many files wait in the inbox. It can never read your book, customers, prices or settings, and it never sees your LAN PIN. Its key is kept in this Mac's Keychain, not in your book.

## The From slicer inbox

What a slicer sends waits under From Your Slicer on the Connected apps screen, with the slicer's own weight and print time, which slicer sent it, and what the slicer asked for (a quote, a job, a print). For each file choose **Add to Library**, **New Job** or **New Quote**, or **Discard**. Nothing becomes a job and no print starts until you choose: what a slicer asked for is only a suggestion. The same file sent twice is kept once, and Khayt tells you so. Up to 100 files can wait. The inbox is a folder beside your book on this Mac; it is not synced or sent anywhere.

## Remove a slicer

On the Connected apps screen, click **Remove…** next to the slicer and confirm. It stops sending to this Mac at once; to use it again, pair it again. The files it already sent stay in your inbox. Changing the LAN PIN also signs out every paired slicer, together with paired phones.

## When pairing doesn't work

- **Pair a slicer is greyed out:** turn on the LAN server and Listen on all network interfaces (LAN) in Settings → Online. If they are on, ask the owner or a manager: your role may not change settings.
- **The slicer can't reach the Mac:** put both computers on the same network (a guest Wi‑Fi often keeps devices apart), type the address exactly, port included, and if the macOS firewall is on, allow Khayt to accept incoming connections.
- **The slicer says pairing is closed:** pairing is open for two minutes and closes once a slicer is approved. Click Pair a slicer again.
- **The LAN PIN couldn't be read from the Keychain:** nothing was paired. Set the LAN PIN again in Settings → Online, then pair again. Setting the PIN signs out phones and slicers, so pair those again too.
- **The slicer says the inbox is full:** 100 files are waiting. Take or discard some, then send again.
