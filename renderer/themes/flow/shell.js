/**
 * Flow shell — dragging a card is how work moves.
 *
 * The board does NOT set order.status itself. It calls updateStatus(), the same
 * function the queue and the kanban tab call, because that is where the rules
 * live: the WIP limit warning (and hard block, when the shop has enabled one),
 * the BOM assembly gate that refuses to complete an order whose parts have not
 * passed QC, the save, and the re-render. A board that assigned status directly
 * would silently bypass all four, and would do it in the one place where moving
 * work is easiest.
 *
 * That also means the board does not need to know whether a move is allowed.
 * It offers the move; updateStatus() accepts or refuses and says why.
 */
(function (global) {
  const DRAG_KEY = 'text/plain';
  let dragId = null;

  function isOn() { return document.body.classList.contains('khayt-flow'); }

  function clearDropState(root) {
    root.querySelectorAll('.flow-col.drop-target, .flow-col.drop-blocked')
      .forEach((c) => c.classList.remove('drop-target', 'drop-blocked'));
  }

  /**
   * Would this land in a column that is already at its limit? Purely for the
   * hover colour — updateStatus() is still the one that decides. Kept in step
   * with it by reading the same settings.wipLimits map and the same rule
   * ("completed" is never limited).
   */
  function wouldBeOverWip(status) {
    // The rule this mirrors (KhaytOrderStatus.wouldExceedWipLimit) exempts
    // every status a job can END in: both spellings of finished, and a quote,
    // which is not work in progress at all. This checked only `completed`, so
    // a column limit could block a shop from filing a quote or from marking a
    // job delivered.
    if (KhaytOrderStatus.FINISHED_STATUSES.includes(status) || status === 'quote') return false;
    const limit = +((typeof settings !== 'undefined' && settings.wipLimits) || {})[status] || 0;
    if (!limit) return false;
    const all = (typeof printLog !== 'undefined' && Array.isArray(printLog)) ? printLog : [];
    const here = all.filter((o) => o.status === status && o.id !== dragId).length;
    return here + 1 > limit;
  }

  function wireBoard(root) {
    if (!root || !isOn()) return;

    root.querySelectorAll('.flow-card[draggable="true"]').forEach((card) => {
      card.addEventListener('dragstart', (e) => {
        dragId = card.dataset.orderId || null;
        card.classList.add('dragging');
        if (e.dataTransfer) {
          e.dataTransfer.effectAllowed = 'move';
          try { e.dataTransfer.setData(DRAG_KEY, dragId || ''); } catch (_) {}
        }
      });
      card.addEventListener('dragend', () => {
        card.classList.remove('dragging');
        clearDropState(root);
        dragId = null;
      });
      // A card is a control, so it opens on Enter or Space like one.
      card.addEventListener('keydown', (e) => {
        if (e.key !== 'Enter' && e.key !== ' ') return;
        e.preventDefault();
        const id = card.dataset.orderId;
        if (id && typeof openOrderDetail === 'function') openOrderDetail(id);
        else if (id && typeof viewOrder === 'function') viewOrder(id);
      });
    });

    root.querySelectorAll('.flow-col').forEach((col) => {
      const status = col.dataset.status;

      col.addEventListener('dragover', (e) => {
        if (!dragId) return;
        e.preventDefault();
        if (e.dataTransfer) e.dataTransfer.dropEffect = 'move';
        clearDropState(root);
        col.classList.add(wouldBeOverWip(status) ? 'drop-blocked' : 'drop-target');
      });

      col.addEventListener('dragleave', (e) => {
        if (!col.contains(e.relatedTarget)) col.classList.remove('drop-target', 'drop-blocked');
      });

      col.addEventListener('drop', (e) => {
        e.preventDefault();
        clearDropState(root);
        const id = dragId || (e.dataTransfer && e.dataTransfer.getData(DRAG_KEY));
        dragId = null;
        if (!id || !status) return;

        const all = (typeof printLog !== 'undefined' && Array.isArray(printLog)) ? printLog : [];
        const order = all.find((o) => o.id === id);
        if (!order || order.status === status) return;   // dropped where it already was

        // Everything that decides whether this is allowed lives in here.
        if (typeof updateStatus === 'function') updateStatus(id, status);
      });
    });
  }

  /* The board is only as current as the store. Re-render on the events that
     change it, so a job finishing on a printer moves its own card. */
  function refresh() {
    if (!isOn()) return;
    if (typeof renderDashboard === 'function') renderDashboard();
  }

  let wired = false;
  function applyFlowShell() {
    if (wired) return;
    wired = true;
    document.addEventListener('languagechange', refresh);
  }

  function teardownFlowShell() {
    document.removeEventListener('languagechange', refresh);
    wired = false;
    dragId = null;
  }

  global.KhaytFlowShell = { applyFlowShell, teardownFlowShell, wireBoard };
})(typeof globalThis !== 'undefined' ? globalThis : window);
