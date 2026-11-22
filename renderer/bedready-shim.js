'use strict';
/**
 * Bed Ready shim — neutralizes the business hooks the SHARED renderer framework
 * expects but that the Bed Ready flavor does not ship.
 *
 * WHY THIS EXISTS: Khayt's shared framework (wire-events.js, dashboard.js,
 * kanban.js, app-boot.js, settings.js ...) references business globals defined in
 * the business renderer modules (clients/logs/analytics/invoicing/expenses/
 * waiting-list/views/online/... .js). Bed Ready deliberately does NOT load those
 * modules, so those globals would be undefined and throw ReferenceError at boot
 * (in listener args, dashboard render, settings render, etc. — note optional
 * calls like `fn?.()` do NOT guard an UNDECLARED identifier). This shim declares
 * them as safe no-ops BEFORE any other script runs. Loaded FIRST in
 * renderer/bedready.html and ONLY there — Khayt never loads it.
 *
 * Function stubs return '' so they're safe as void calls and inside `${fn()}`
 * templates. Value globals get inert empties. This list is GENERATED from the
 * dropped-module set (see electron-builder.bedready.js EXCLUDED_BUSINESS_RENDERER);
 * regenerate if that set changes.
 */
(function () {
  const g = (typeof window !== 'undefined') ? window : globalThis;
  const noop = function () { return ''; };

  // --- business functions referenced by the shared framework (no-ops) ---
  const FNS = ["addExpense","aiDraftReply","applyOnlineLanPrefs","approveQuote","batchArchiveOrders","batchAssignMachine","batchExportPDFs","batchMoveStatus","batchWaSend","captureFailurePhoto","checkAndSendDigest","checkRecurringExpenses","checkRecurringOrders","checkSubscriptionBilling","clearAllLogs","clearLogFilters","clearPayment","copyIntakeLink","copyOnlineIntakeUrl","deleteClient","deleteExpense","deleteLog","deleteSlicerProfile","dispatchPrinterAlerts","duplicateOrder","emailOrderToClient","expCatLabel","exportAccounting","exportAccountingCSV","exportAnalyticsReport","exportClientsCsv","exportExpensesCsv","exportGaztVatReturn","exportIcalFeed","exportInvoicePDF","exportOrdersCsv","exportOrderStatusPage","exportPnlCsv","exportTaxSummary","fireWebhook","formatPrintDate","generateCreditNote","generateDeliveryNote","generateIntakeForm","generateInvoice","generateMilestoneInvoice","generateOrderLabel","generatePackingSlip","generateProformaInvoice","generateSurveyPage","getCarrierTrackingUrl","getFilteredLogs","hideClientSuggestions","holdOrder","loadLanQr","logPrint","markDelivered","nextInvoiceNumber","openBatchPlannerModal","openBnplModal","openCampaignModal","openChangeOrderModal","openClientEditor","openClientHistory","openCreateGiftCardModal","openCreditNoteModal","openCustomerPortalModal","openEditHistoryModal","openEndOfDayReport","openExecutiveSummary","openLogEnvModal","openOrderEditor","openOrderRequestsModal","openOrderTimeline","openPartialDeliveryModal","openPaymentModal","openPortalMessages","openQuoteApprovalLinkModal","openQuoteRevisionsModal","openRecordSurveyModal","openReminderModal","openReportBuilder","openAssemblyModal","openRmaModal","openSavedStatusPage","openShipModal","openShiftChecklistModal","openSlicerProfileModal","openSpoolSwitchModal","openSubscriptionsModal","openWaitingItemEditor","paymentBadge","populateExpOrderDatalist","processPaymentReminders","processQuoteFollowUps","processRecurringOrders","promoteWaitingItem","qcFailOrder","qcPassOrder","quoteForClient","reconcileLanServerStatus","refreshLanIntakePinLive","rejectQuote","renderAnalytics","renderBatchBar","renderBreakEvenCard","renderCalendarView","renderCapacityGauge","renderClients","renderClientSuggestions","renderEnvLogs","renderExpenses","renderGiftCards","renderInvoiceNumberingSection","renderKioskView","renderLogs","renderOnlineSettings","renderPortfolio","renderPostProcessPresetsList","renderReferralAnalytics","renderScheduleView","renderSimpleReports","renderSlicerProfiles","renderSupplierPriceHistory","renderWaitingList","reprintOrder","resinCompletePost","resinLogCure","resinLogWash","reviseQuote","sendPaymentReminder","sendQuoteFollowUp","shareInvoiceWhatsApp","shareTrackingWhatsApp","showLinkedExpenses","splitOrderAcrossMachines","startLanServer","startPaymentReminderTimer","startQuoteFollowUpTimer","startTunnelFromSettings","submit","submitOrderToZatca","tlv","updateStatus","updateWaitingBadge","updateWebhookUrlDisplay","voidInvoice"];
  for (const n of FNS) { if (typeof g[n] === 'undefined') g[n] = noop; }

  // --- business value globals (inert defaults) ---
  if (typeof g.BNPL_CATALOG === 'undefined') g.BNPL_CATALOG = [];
  if (typeof g.EXP_CATEGORIES === 'undefined') g.EXP_CATEGORIES = [];
  if (typeof g.BRAND_MARK_SVG === 'undefined') g.BRAND_MARK_SVG = '';
  if (typeof g.clientSearchTerm === 'undefined') g.clientSearchTerm = '';
  if (typeof g.clientSortCol === 'undefined') g.clientSortCol = '';
  if (typeof g.clientSortDir === 'undefined') g.clientSortDir = '';
  if (typeof g.expRangeFilter === 'undefined') g.expRangeFilter = '';
  if (typeof g.portfolioSearchTerm === 'undefined') g.portfolioSearchTerm = '';
})();
