'use strict';

/** IPC channels that return null when denied (match handler contracts). */
const DENY_NULL = new Set([
  'hub:restore-backup',
  'hub:write-icloud-backup',
  'hub:write-status-page',
  'hub:load-product-image',
  'hub:load-order-photo',
  'hub:pick-and-save-order-file',
  'hub:open-order-file',
  'hub:open-file',
  'hub:parse-print-file',
]);

/** @returns {unknown} Safe denial payload per channel. */
function hubIpcDenied(channel) {
  if (channel === 'hub:load-store') {
    return { __corrupt: true, error: 'unauthorized_sender' };
  }
  if (DENY_NULL.has(channel)) return null;
  if (channel === 'hub:app-version') return '0.0.0';
  if (channel === 'hub:store-size') return 0;
  if (channel === 'hub:get-printer-status') return {};
  if (channel === 'hub:generate-qr') return '';
  if (channel === 'hub:list-backups') return [];
  if (channel === 'hub:get-lan-url' || channel === 'hub:get-tunnel-url') {
    return { ok: false, error: 'unauthorized_sender' };
  }
  return { ok: false, error: 'unauthorized_sender' };
}

/**
 * Wrap ipcMain.handle so every hub:* channel requires the main BrowserWindow sender.
 * @param {import('electron').IpcMain} ipcMain
 * @param {(event: import('electron').IpcMainInvokeEvent) => boolean} isTrustedRenderer
 */
function wrapHubIpc(ipcMain, isTrustedRenderer) {
  if (ipcMain.__khaytHubGuard) return;
  ipcMain.__khaytHubGuard = true;
  const nativeHandle = ipcMain.handle.bind(ipcMain);
  ipcMain.handle = (channel, listener) => {
    nativeHandle(channel, async (event, ...args) => {
      if (typeof channel === 'string' && channel.startsWith('hub:') && !isTrustedRenderer(event)) {
        return hubIpcDenied(channel);
      }
      return listener(event, ...args);
    });
  };
}

module.exports = { wrapHubIpc, hubIpcDenied, DENY_NULL };
