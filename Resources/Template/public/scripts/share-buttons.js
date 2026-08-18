// Share-button click handler for ShareButtons.astro. Served as a same-origin static file
// (rather than an Astro `is:inline` inline script body) so the site's CSP script-src 'self'
// policy (no 'unsafe-inline') covers it.
(function () {
  document.addEventListener("click", function (e) {
    var target = e.target.closest("[data-share-mastodon], [data-share-copy]");
    if (!target) return;
    if (target.hasAttribute("data-share-mastodon")) {
      var instance = window.localStorage.getItem("mastodon-share-instance");
      if (!instance) {
        instance = window.prompt("Your Mastodon instance (e.g. mastodon.social):");
        if (!instance) return;
        instance = instance.replace(/^https?:\/\//, "").replace(/\/$/, "");
        window.localStorage.setItem("mastodon-share-instance", instance);
      }
      var text = target.getAttribute("data-share-text") + " " + target.getAttribute("data-share-url");
      window.open("https://" + instance + "/share?text=" + encodeURIComponent(text), "_blank", "noopener,noreferrer");
    } else if (target.hasAttribute("data-share-copy")) {
      navigator.clipboard.writeText(target.getAttribute("data-share-url")).then(function () {
        var original = target.textContent;
        target.textContent = "Copied!";
        window.setTimeout(function () { target.textContent = original; }, 2000);
      });
    }
  });
})();
