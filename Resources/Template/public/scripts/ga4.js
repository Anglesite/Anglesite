// GA4 gtag.js init for TrackingScript.astro. Served as a same-origin static file (rather than
// an Astro `is:inline define:vars` script body) so the site's CSP script-src 'self' policy
// (no 'unsafe-inline') covers it. The measurement ID comes from a data-ga4-measurement-id
// attribute on this script's own tag (read via document.currentScript, valid because this
// script runs synchronously — no async/defer) instead of a server-injected variable.
(function () {
  var measurementId = document.currentScript.dataset.ga4MeasurementId;
  window.dataLayer = window.dataLayer || [];
  function gtag() { dataLayer.push(arguments); }
  gtag("js", new Date());
  gtag("config", measurementId);
})();
