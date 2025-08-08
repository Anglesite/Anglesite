/**
 * Type definitions for the secure Electron API
 */
interface ElectronAPI {
  send: (channel: string, ...args: unknown[]) => void;
  on: (channel: string, func: (...args: unknown[]) => void) => void;
  removeAllListeners: (channel: string) => void;
}

declare global {
  interface Window {
    electronAPI: ElectronAPI;
  }
}

export {};
