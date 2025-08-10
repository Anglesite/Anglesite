/**
 * Type definitions for the secure Electron API
 */
interface ThemeInfo {
  userPreference: 'system' | 'light' | 'dark';
  resolvedTheme: 'light' | 'dark';
  systemTheme: 'light' | 'dark';
}

interface ElectronAPI {
  send: (channel: string, ...args: unknown[]) => void;
  invoke: (channel: string, ...args: unknown[]) => Promise<unknown>;
  on: (channel: string, func: (...args: unknown[]) => void) => void;
  removeAllListeners: (channel: string) => void;
  // Theme API methods
  getCurrentTheme: () => Promise<ThemeInfo>;
  setTheme: (theme: 'system' | 'light' | 'dark') => Promise<ThemeInfo>;
  onThemeUpdated: (callback: (themeInfo: ThemeInfo) => void) => void;
}

declare global {
  interface Window {
    electronAPI: ElectronAPI;
  }
}

export {};
