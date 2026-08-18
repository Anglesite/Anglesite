// Consent banner controller for ConsentBanner.astro. Served as a same-origin static file
// (rather than an Astro `is:inline define:vars` script body) so the site's CSP script-src
// 'self' policy (no 'unsafe-inline') covers it. Per-instance config comes from data-consent-*
// attributes on #consent-banner instead of server-injected variables.
(function () {
  var banner = document.getElementById("consent-banner");
  if (!banner) return;

  var config = {
    categories: (banner.dataset.consentCategories || "").split(",").filter(Boolean),
    defaultPolicy: banner.dataset.consentDefaultPolicy,
    version: banner.dataset.consentVersion,
  };
  var STORAGE_KEY = "consent";
  var COOKIE_DAYS = 180;

  function readCookie(name) {
    var match = document.cookie.match(new RegExp("(?:^|; )" + name + "=([^;]*)"));
    return match ? decodeURIComponent(match[1]) : null;
  }
  function writeCookie(name, value, days) {
    var expires = new Date(Date.now() + days * 24 * 60 * 60 * 1000).toUTCString();
    var secure = window.location.protocol === "https:" ? "; Secure" : "";
    document.cookie = name + "=" + encodeURIComponent(value) + "; expires=" + expires + "; path=/; SameSite=Lax" + secure;
  }
  function isEUVisitor() {
    // Known gap: EU/EEA overseas territories with a non-Europe/Atlantic IANA zone name
    // (e.g. America/Cayenne for French Guiana, Indian/Reunion, America/Guadeloupe,
    // America/Martinique, Indian/Mayotte) are not matched here and get default-allow under
    // the "geo" policy, even though GDPR applies to them. A visitor-IP-based lookup (e.g. via
    // Cloudflare's request.cf.country at the edge) would cover this properly; this
    // client-side timezone heuristic is a best-effort approximation, not exhaustive.
    try {
      var tz = Intl.DateTimeFormat().resolvedOptions().timeZone || "";
      return /^(Europe|Atlantic\/(Canary|Faroe|Reykjavik))\//.test(tz);
    } catch (e) {
      return false;
    }
  }
  function defaultGrants() {
    var grants = {};
    if (config.defaultPolicy === "geo" && !isEUVisitor()) {
      config.categories.forEach(function (c) { grants[c] = true; });
    }
    return grants;
  }
  function loadState() {
    var raw = readCookie(STORAGE_KEY);
    if (!raw) return null;
    try {
      var parsed = JSON.parse(raw);
      if (parsed.version !== config.version) return null;
      return parsed;
    } catch (e) {
      return null;
    }
  }
  function saveState(grants) {
    writeCookie(STORAGE_KEY, JSON.stringify({ version: config.version, grants: grants }), COOKIE_DAYS);
  }
  function applyGrants(grants) {
    document.querySelectorAll("[data-consent]").forEach(function (el) {
      var category = el.getAttribute("data-consent");
      if (!grants[category]) return;
      // data-src is authored by the site owner in the Astro template, never by runtime visitor
      // content — this gates a config-time embed URL, not user-generated input. It's restricted
      // to https:// (blocking javascript: execution) and, regardless, the site's CSP script-src
      // and frame-src baseline (scripts/csp.ts) already reject loading from any origin the
      // owner hasn't explicitly allowed. CodeQL's static analysis can't see that cross-file
      // scheme + origin defense, so it still flags this generic "attribute drives a URL sink"
      // shape as XSS.
      var dataSrc = el.getAttribute("data-src");
      if (dataSrc && dataSrc.startsWith("https://")) {
        el.setAttribute("src", dataSrc); // codeql[js/xss-through-dom] -- see comment above
      }
      if (el.tagName === "SCRIPT" && el.getAttribute("type") === "text/plain") {
        var replacement = document.createElement("script");
        for (var i = 0; i < el.attributes.length; i++) {
          var attr = el.attributes[i];
          if (attr.name !== "type") replacement.setAttribute(attr.name, attr.value);
        }
        replacement.text = el.text;
        el.replaceWith(replacement);
      }
    });
  }
  function hide(el) { if (el) el.hidden = true; }
  function show(el) { if (el) el.hidden = false; }

  var modal = document.getElementById("consent-modal");
  var stored = loadState();
  var grants = stored ? stored.grants : defaultGrants();
  applyGrants(grants);
  if (!stored) show(banner);

  document.addEventListener("click", function (e) {
    var target = e.target;
    var action = target && target.getAttribute && target.getAttribute("data-consent-action");
    if (!action) return;
    if (action === "accept") {
      var all = {};
      config.categories.forEach(function (c) { all[c] = true; });
      grants = all;
      saveState(grants);
      applyGrants(grants);
      hide(banner);
      hide(modal);
    } else if (action === "reject") {
      grants = {};
      saveState(grants);
      hide(banner);
      hide(modal);
    } else if (action === "preferences") {
      hide(banner);
      show(modal);
      config.categories.forEach(function (c) {
        var input = modal.querySelector('[data-consent-category="' + c + '"]');
        if (input) input.checked = !!grants[c];
      });
    } else if (action === "save") {
      var next = {};
      config.categories.forEach(function (c) {
        var input = modal.querySelector('[data-consent-category="' + c + '"]');
        next[c] = !!(input && input.checked);
      });
      grants = next;
      saveState(grants);
      applyGrants(grants);
      hide(modal);
    }
  });
})();
