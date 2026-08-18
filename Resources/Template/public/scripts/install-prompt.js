// PWA install-prompt controller for InstallPrompt.astro. Served as a same-origin static file
// (rather than an Astro `is:inline` inline script body) so the site's CSP script-src 'self'
// policy (no 'unsafe-inline') covers it.
(function () {
  var DISMISS_KEY = "pwa-install-dismissed";
  var DISMISS_MS = 30 * 24 * 60 * 60 * 1000;
  var banner = document.querySelector(".install-prompt");
  if (!banner) return;

  var dismissed = localStorage.getItem(DISMISS_KEY);
  if (dismissed && Date.now() - parseInt(dismissed, 10) < DISMISS_MS) return;

  var deferredPrompt = null;

  window.addEventListener("beforeinstallprompt", function (e) {
    e.preventDefault();
    deferredPrompt = e;
    banner.hidden = false;
  });

  banner.addEventListener("click", function (e) {
    var action = e.target && e.target.dataset && e.target.dataset.action;
    if (action === "install" && deferredPrompt) {
      deferredPrompt.prompt();
      deferredPrompt.userChoice.then(function () {
        deferredPrompt = null;
        banner.hidden = true;
      });
    } else if (action === "dismiss") {
      localStorage.setItem(DISMISS_KEY, String(Date.now()));
      banner.hidden = true;
    }
  });

  window.addEventListener("appinstalled", function () {
    banner.hidden = true;
  });
})();
