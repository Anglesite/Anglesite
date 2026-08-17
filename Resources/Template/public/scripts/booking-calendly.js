// Calendly embed loader for BookingWidget.astro. Served as a same-origin static file (rather
// than an Astro `is:inline define:vars` script body) so the site's CSP script-src 'self' policy
// (no 'unsafe-inline') covers it. Per-instance config comes from data-calendly-* attributes
// instead of server-injected variables.
document.querySelectorAll("[data-calendly-init]").forEach(function (el) {
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
