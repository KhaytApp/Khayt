'use strict';
/**
 * The 3MF converter's utilityProcess: a plain Node child that answers one job at a time.
 *
 * It exists so the work in lib/mf-jobs.js happens somewhere other than the thread drawing
 * the app. It holds no state between jobs and makes no decisions — every path it touches
 * was validated by the parent before the message was sent, and the parent owns the ceiling
 * on how much it is allowed to read.
 *
 * A crash here (a file that inflates past what the machine can hold) takes this process and
 * nothing else; the parent notices the exit, fails the jobs that were in flight, and forks
 * a new one on the next request.
 */
const jobs = require('./mf-jobs');

const port = process.parentPort;

if (port) {
  port.on('message', async (e) => {
    const msg = (e && e.data) || {};
    const { id, op, args } = msg;
    let res;
    try {
      res = await jobs.run(op, args);
    } catch (err) {
      // jobs.run already converts its own failures into results; this is the last resort.
      res = { ok: false, available: false, error: String((err && err.message) || err) };
    }
    try {
      port.postMessage({ id, res });
    } catch (_) {
      // The parent went away mid-job. Nothing to report to and nothing to clean up.
    }
  });
}
