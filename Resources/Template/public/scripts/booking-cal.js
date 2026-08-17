// Cal.com embed loader for BookingWidget.astro. Served as a same-origin static file (rather
// than an Astro `is:inline define:vars` script body) so the site's CSP script-src 'self' policy
// (no 'unsafe-inline') covers it. Per-instance config comes from data-cal-* attributes instead
// of server-injected variables.
(function (C, A, L) {
  let p = function (a, ar) {
    a.q.push(ar);
  };
  let d = C.document;
  C.Cal =
    C.Cal ||
    function () {
      let cal = C.Cal;
      let ar = arguments;
      if (!cal.loaded) {
        cal.ns = {};
        cal.q = cal.q || [];
        d.head.appendChild(d.createElement("script")).src = A;
        cal.loaded = true;
      }
      if (ar[0] === L) {
        const api = function () {
          p(api, arguments);
        };
        const namespace = ar[1];
        api.q = api.q || [];
        typeof namespace === "string" ? ((cal.ns[namespace] = api), p(api, ar)) : p(cal, ar);
        return;
      }
      p(cal, ar);
    };
})(window, "https://app.cal.com/embed/embed.js", "init");

Cal("init", { origin: "https://cal.com" });

document.querySelectorAll("[data-cal-init]").forEach(function (el) {
  const calLink = el.dataset.calLink;
  const config = { theme: "auto", brandColor: el.dataset.calColor };
  switch (el.dataset.calInit) {
    case "inline":
      Cal("inline", { elementOrSelector: "#" + el.id, calLink, config });
      break;
    case "floating":
      Cal("floatingButton", { calLink, buttonText: el.dataset.calButtonText, config });
      break;
    case "button":
      Cal("pop", { calLink, config });
      break;
  }
});
