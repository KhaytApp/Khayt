'use strict';

/**
 * The MakerRun host — ONE constant, on purpose.
 *
 * BedReady split into two products on 2026-08-21. The design library Khayt talks to
 * is now **MakerRun** at `makerrun.com`; `bedready.io` kept the *converter* and is a
 * different product with no API. So a `bedready.io` string elsewhere in this repo is
 * not necessarily stale — the colour/mesh ports and the Bed Ready flavor's own site
 * links still mean the converter, and must stay. Only what talks to the *library*
 * lives here.
 *
 * Two modules call MakerRun (lib/makerrun-account, lib/makerrun-library) and both used
 * to carry their own copy of the host. That is the shape where a move lands in one of
 * them and the other silently keeps talking to the old address, so the host is defined
 * once and imported.
 *
 * `bedready.io/api/*` is still served as a compatibility alias for clients pinned to
 * the old base, deliberately excluded from the cross-origin 301s that now move the page
 * routes. It is an alias, not the address: it carries no forever guarantee, and a 301
 * on a POST is how you lose a request body.
 *
 * Deliberately NOT an environment variable. `/api/app-token` carries the refresh token
 * and `/api/library` carries the user's Bearer, and an ambient override would let a
 * stray env var point either at an arbitrary host. Tests inject a base by parameter.
 */
const BASE = 'https://makerrun.com';

module.exports = { BASE };
