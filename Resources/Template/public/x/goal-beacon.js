// Edge A/B testing client-side goal beacon (#1270 slice 2).
//
// A first-party static file — never bundled or transformed — injected by BaseLayout.astro only
// on a running experiment's own page/variant page, and only when that experiment's goal is
// "scroll" or "visible". Goal parameters travel as data- attributes on the injecting <script> tag
// (read via document.currentScript), never inline. Observes at most one goal crossing per page
// view and reports it to /x/goal; never chooses or swaps page content, so it has no bearing on
// variant assignment (that stays entirely server-side — see worker/experiments.ts).
(() => {
  "use strict";
  const script = document.currentScript;
  if (!script) return;

  const experimentId = script.dataset.experiment;
  const kind = script.dataset.kind;
  if (!experimentId || (kind !== "scroll" && kind !== "visible")) return;

  let fired = false;
  function send() {
    if (fired) return;
    fired = true;
    const url = "/x/goal?e=" + encodeURIComponent(experimentId);
    if (navigator.sendBeacon) {
      navigator.sendBeacon(url);
    } else {
      fetch(url, { method: "POST", keepalive: true }).catch(() => {});
    }
  }

  if (kind === "scroll") {
    const depth = Number(script.dataset.depth);
    if (!(depth > 0 && depth <= 100)) return;
    const onScroll = () => {
      const doc = document.documentElement;
      const scrolled = ((window.scrollY + window.innerHeight) / doc.scrollHeight) * 100;
      if (scrolled >= depth) {
        window.removeEventListener("scroll", onScroll);
        send();
      }
    };
    window.addEventListener("scroll", onScroll, { passive: true });
  } else {
    const selector = script.dataset.selector;
    if (!selector) return;
    const target = document.querySelector(selector);
    if (!target) return;
    const observer = new IntersectionObserver((entries) => {
      if (entries.some((entry) => entry.isIntersecting)) {
        observer.disconnect();
        send();
      }
    });
    observer.observe(target);
  }
})();
