# Stabilization checklist (v2.3.x)

Use this before the next public release after **v2.3.1**. Shipped fixes: portal tracking `?token=`, operator PIN flush, UTC `calcNextDueDate`, npm audit overrides.

## Build verification

```bash
npm run check
npm start
# optional: npm run test:e2e
```

## Manual smoke (desktop)

| Area | Steps | Pass? |
|------|--------|-------|
| **Boot** | Fresh start, wizard skipped, dashboard loads | ☐ |
| **Store** | Add order, restart app, data persists | ☐ |
| **LAN tracking** | Start LAN → copy tracking link → open in phone browser (same Wi‑Fi) | ☐ |
| **Portal QR** | Order menu → Portal QR → scan/copy URL → opens tracking (not 403) | ☐ |
| **Quote link** | Quote order → quote approval link → opens approval page | ☐ |
| **Operator PIN** | Set operator PIN → switch operator with PIN pad | ☐ |
| **Import** | Settings import JSON → data fully replaces (no ghost old clients) | ☐ |
| **Backup restore** | Restore backup → same full replace | ☐ |
| **Update** | From 2.3.0 build, check for updates (no infinite “Saving data…”) | ☐ |

## Known limits (not bugs)

- Operator lock hides UI tabs only; does not encrypt the store file.
- Old `/status/*.html` files on disk may exist until re-exported; LAN serves redacted copy.
- Quote **GET** `/order/:id/quote` is public; **approve POST** requires token.

## Report issues

Note: steps, expected vs actual, app version (Settings → About), OS. Fix on `cursor/stabilization-2-3-x-d4c8`, merge to `main` when ready — hold **tag/release** until batch is approved.
