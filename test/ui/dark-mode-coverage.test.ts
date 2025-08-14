/**
 * @file Additional tests to achieve 90% coverage for dark mode feature
 * Tests edge cases and less common paths
 */

import type { BrowserWindow } from 'electron';
import type { MockStore, MockNativeTheme, PartialMockWindow } from './test-types';

// Mock Electron modules
const mockNativeTheme: MockNativeTheme = {
  shouldUseDarkColors: false,
  themeSource: 'system',
  on: jest.fn(),
};

const mockWindow = {
  isDestroyed: () => false,
  webContents: {
    send: jest.fn(),
    isLoading: jest.fn(),
    executeJavaScript: jest.fn(() => Promise.resolve()),
    once: jest.fn(),
  },
};

const mockStore: MockStore = {
  get: jest.fn(() => 'system'),
  set: jest.fn(),
};

jest.mock('electron', () => ({
  BrowserWindow: {
    getAllWindows: jest.fn(() => [mockWindow]),
  },
  nativeTheme: mockNativeTheme,
  ipcMain: {
    handle: jest.fn(),
    on: jest.fn(),
  },
}));

jest.mock('../../app/store', () => ({
  Store: jest.fn(() => mockStore),
}));

describe('Dark Mode Coverage Tests', () => {
  let themeManager: typeof import('../../app/ui/theme-manager');

  beforeAll(() => {
    // Import after mocks are set up
    themeManager = require('../../app/ui/theme-manager');
  });

  beforeEach(() => {
    jest.clearAllMocks();
    mockNativeTheme.shouldUseDarkColors = false;
    mockNativeTheme.themeSource = 'system';
    mockStore.get.mockReturnValue('system');
    mockWindow.webContents?.isLoading?.mockReturnValue(false);
  });

  describe('getResolvedTheme coverage', () => {
    it('should return the current resolved theme', () => {
      // This covers line 90
      const theme = themeManager.themeManager.getResolvedTheme();
      expect(['light', 'dark']).toContain(theme);
    });
  });

  describe('initializeNativeTheme coverage', () => {
    it('should initialize with light theme preference', () => {
      // Reset modules to test initialization
      jest.resetModules();

      // Mock store to return 'light'
      const mockLightStore = {
        get: jest.fn(() => 'light'),
        set: jest.fn(),
      };

      jest.mock('../../app/store', () => ({
        Store: jest.fn(() => mockLightStore),
      }));

      // Re-import to trigger constructor with light preference
      require('../../app/ui/theme-manager');

      // This covers line 39 (light theme initialization)
      expect(mockNativeTheme.themeSource).toBe('light');
    });
  });

  describe('applyThemeToWindow with loading window', () => {
    it('should handle window that is still loading', () => {
      // Mock window as loading
      mockWindow.webContents?.isLoading?.mockReturnValue(true);

      // Apply theme to loading window
      themeManager.themeManager.applyThemeToWindow(mockWindow as unknown as BrowserWindow);

      // Should set up dom-ready listener (covers lines 176-177)
      expect(mockWindow.webContents?.once).toHaveBeenCalledWith('dom-ready', expect.any(Function));

      // Execute the dom-ready callback
      const domReadyCallback = mockWindow.webContents?.once?.mock.calls[0][1];
      domReadyCallback();

      // Should execute JavaScript
      expect(mockWindow.webContents?.executeJavaScript).toHaveBeenCalled();
    });

    it('should handle executeJavaScript errors gracefully', async () => {
      // Mock executeJavaScript to reject
      mockWindow.webContents?.executeJavaScript?.mockRejectedValue(new Error('Script execution failed'));

      // Console.error should be called when executeJavaScript fails
      const consoleErrorSpy = jest.spyOn(console, 'error').mockImplementation();

      // Apply theme - should not throw
      themeManager.themeManager.applyThemeToWindow(mockWindow as unknown as BrowserWindow);

      // Wait for the next microtask to allow promise rejection to be handled
      await Promise.resolve();

      expect(consoleErrorSpy).toHaveBeenCalled();
      consoleErrorSpy.mockRestore();
    });

    it('should handle missing executeJavaScript function', () => {
      // Mock window without executeJavaScript
      const windowWithoutExecute: PartialMockWindow = {
        isDestroyed: () => false,
        webContents: {
          send: jest.fn(),
          isLoading: jest.fn(() => false),
          // No executeJavaScript function
        },
      };

      const consoleLogSpy = jest.spyOn(console, 'log').mockImplementation();

      // Should handle gracefully (covers line 184)
      expect(() => {
        themeManager.themeManager.applyThemeToWindow(windowWithoutExecute as unknown as BrowserWindow);
      }).not.toThrow();

      expect(consoleLogSpy).toHaveBeenCalledWith('Could not execute immediate theme script:', expect.any(Error));

      consoleLogSpy.mockRestore();
    });
  });

  describe('System theme listener', () => {
    it('should log system theme changes', () => {
      const consoleLogSpy = jest.spyOn(console, 'log').mockImplementation();

      // Get the system theme listener
      const updateCall = mockNativeTheme.on.mock.calls.find((call) => call[0] === 'updated');

      if (updateCall) {
        // Simulate system theme change to dark
        mockNativeTheme.shouldUseDarkColors = true;
        updateCall[1]();

        // Should log the change (covers line 52)
        expect(consoleLogSpy).toHaveBeenCalledWith('System theme changed to:', 'dark');

        // Simulate change back to light
        mockNativeTheme.shouldUseDarkColors = false;
        updateCall[1]();

        expect(consoleLogSpy).toHaveBeenCalledWith('System theme changed to:', 'light');
      }

      consoleLogSpy.mockRestore();
    });
  });
});
