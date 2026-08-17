import { renderPopup } from "./popup/render";
import type { Findings } from "./types";

declare const chrome: {
  tabs: { query(info: { active: boolean; currentWindow: boolean }): Promise<{ id?: number }[]> };
  storage: { session: { get(key: string): Promise<Record<string, unknown>> } };
};

async function main(): Promise<void> {
  const container = document.getElementById("app");
  if (!container) return;

  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (tab?.id === undefined) {
    renderPopup(container, null);
    return;
  }

  const stored = await chrome.storage.session.get(String(tab.id));
  const findings = (stored[String(tab.id)] as Findings | null | undefined) ?? null;
  renderPopup(container, findings);
}

document.addEventListener("click", (event) => {
  const target = event.target;
  if (target instanceof HTMLElement && target.dataset.vcard) {
    void navigator.clipboard.writeText(target.dataset.vcard);
  }
});

void main();
