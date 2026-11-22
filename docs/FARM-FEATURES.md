# Print farm features (local, one store file)

Khayt supports **multiple branches inside one shop** using **Locations** (Settings → Operations → Locations). This is not Khayt Cloud multi-shop sync — see [MULTI-SHOP-CLOUD.md](./MULTI-SHOP-CLOUD.md).

## Setup

1. **Settings → Preferences** — set mode to **Professional** (or pick **Print farm** in the setup wizard).
2. **Settings → Operations → Locations** — add each site (e.g. Riyadh, Jeddah).
3. **Settings → Printers** — assign each printer to a **location**.
4. Orders inherit site from the **assigned machine** on the order.

## Daily use

| Feature | Where |
|--------|--------|
| Filter one site | Top bar **location** dropdown |
| All sites KPIs | Dashboard **Sites overview** (click a card to filter) |
| Per-printer queues | **Production Queue** (respects location filter) |
| WIP limits | Settings → Operations |

Jobs with **no machine / no location** still appear when filtering (so nothing is lost until you assign a printer).

## Wizard preset

Choosing **Print farm** in setup:

- Sets **Professional** mode
- Applies starter **WIP limits** (pending / printing / post / QC)
- Adds a second location **Site 2** if you only had one

## Roadmap (not in this batch)

- Khayt Cloud sync across separate installs
- Per-location inventory splits
- Operator roles per site
