export const TOAST_CLASS = "anglesite-toast";

/**
 * Mount a small bottom-right toast with the given text. Auto-dismisses after
 * `durationMs` (default 4000). Stacks: subsequent toasts appear above earlier
 * ones until they self-remove.
 */
export function showToast(text: string, durationMs = 4000): void {
  ensureStyles();
  const el = document.createElement("div");
  el.className = TOAST_CLASS;
  el.textContent = text;
  const existing = document.querySelectorAll(`.${TOAST_CLASS}`).length;
  el.style.bottom = `${16 + existing * 56}px`;
  document.body.appendChild(el);

  setTimeout(() => {
    el.remove();
  }, durationMs);
}

let stylesInstalled = false;
function ensureStyles(): void {
  if (stylesInstalled) return;
  stylesInstalled = true;
  const style = document.createElement("style");
  style.setAttribute("data-anglesite-toast", "");
  style.textContent = `
.${TOAST_CLASS} {
  position: fixed;
  right: 16px;
  bottom: 16px;
  max-width: 360px;
  padding: 10px 14px;
  background: rgba(20, 20, 24, 0.92);
  color: #fff;
  font: 13px/1.4 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
  border-radius: 8px;
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.25);
  z-index: 2147483647;
  pointer-events: none;
}
`;
  document.head.appendChild(style);
}
