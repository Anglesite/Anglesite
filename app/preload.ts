/**
 * @file Preload script for the Electron application.
 * @see {@link https://www.electronjs.org/docs/latest/tutorial/process-model#preload-scripts}
 */
import { contextBridge, ipcRenderer } from "electron";

// Expose protected methods that allow the renderer process to use
// the ipcRenderer without exposing the entire object
contextBridge.exposeInMainWorld("electronAPI", {
  send: (channel: string, ...args: unknown[]) => {
    // Whitelist channels for security
    const validChannels = [
      "new-website",
      "preview",
      "open-browser",
      "reload-preview",
      "toggle-devtools",
      "hide-preview",
    ];
    if (validChannels.includes(channel)) {
      ipcRenderer.send(channel, ...args);
    }
  },
  on: (channel: string, func: (...args: unknown[]) => void) => {
    // Whitelist channels for security
    const validChannels = [
      "preview-loaded",
      "preview-error",
      "menu-new-website",
      "menu-reload",
      "menu-toggle-devtools",
    ];
    if (validChannels.includes(channel)) {
      ipcRenderer.on(channel, (_event, ...args) => func(...args));
    }
  },
  removeAllListeners: (channel: string) => {
    const validChannels = ["preview-loaded", "preview-error"];
    if (validChannels.includes(channel)) {
      ipcRenderer.removeAllListeners(channel);
    }
  },
});
