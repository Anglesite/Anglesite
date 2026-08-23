// The injected entry point: bundled as an IIFE and evaluated in the capture WKWebView, where it
// installs a global the Swift side calls to pull the extracted record back out as JSON.
import { extractPage } from "./extract.ts";

declare global {
  interface Window {
    __anglesiteImportExtract: () => string;
  }
}

window.__anglesiteImportExtract = () => JSON.stringify(extractPage(document, document.location.href));
