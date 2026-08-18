// Calendly embed loader for BookingWidget.astro. Served as a same-origin static file (rather
// than an Astro `is:inline define:vars` script body) so the site's CSP script-src 'self' policy
// (no 'unsafe-inline') covers it. Per-instance config comes from data-calendly-* attributes
// instead of server-injected variables.
// This script isn't deduplicated by Astro across multiple `is:inline` instances on the same
// page (e.g. a site-wide floating widget plus the always-present inline widget on the book
// page), so it can run more than once. Skip elements a prior run already initialized.
document.querySelectorAll("[data-calendly-init]:not([data-calendly-processed])").forEach(function (el) {
  el.dataset.calendlyProcessed = "";
  const calendlyUrl = el.dataset.calendlyUrl;
  switch (el.dataset.calendlyInit) {
    case "floating":
      window.addEventListener("load", function () {
        Calendly.initBadgeWidget({
          url: calendlyUrl,
          text: el.dataset.buttonText,
          color: el.dataset.brandColor,
          textColor: "#ffffff",
        });
      });
      break;
    case "button":
      el.addEventListener("click", function (e) {
        e.preventDefault();
        Calendly.initPopupWidget({ url: calendlyUrl });
      });
      break;
  }
});
