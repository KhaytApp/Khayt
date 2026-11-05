# Off-site backup fixture

Written by the desktop (`lib/offsite-backup.js` `seal`) so the Mac can prove it opens it with KhaytCore `OffsiteBackup.open`.

- `khayt-book-2026-11-05.khaytbak`: the sealed file, exactly as a desktop off-site backup writes it.
- `book.json`: the bytes it must open to.
- The data key is 32 bytes `01 02 03 … 20` (hex `0102…1f20`), a test key, not anyone's.

Regenerating it changes the ciphertext (random IV); both apps' tests must then still open it.
