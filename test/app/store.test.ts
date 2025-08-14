/**
 * @file Tests for Store class functionality
 */

import * as fs from 'fs';
import * as path from 'path';

// Mock Electron app module
jest.mock('electron', () => ({
  app: {
    getPath: jest.fn(),
  },
}));

// Mock fs module
jest.mock('fs');
const mockedFs = fs as jest.Mocked<typeof fs>;

// Mock path module
jest.mock('path');
const mockedPath = path as jest.Mocked<typeof path>;

// Import after mocking
import { Store, AppSettings, WindowState } from '../../app/store';

describe('Store', () => {
  let store: Store;
  let mockUserDataPath: string;
  let mockSettingsPath: string;
  let consoleSpy: jest.SpyInstance;
  let mockApp: { getPath: jest.Mock };

  beforeEach(() => {
    // Reset all mocks
    jest.clearAllMocks();

    // Get the mocked app
    mockApp = require('electron').app;

    // Set up mock paths
    mockUserDataPath = '/mock/user/data';
    mockSettingsPath = '/mock/user/data/settings.json';

    mockApp.getPath.mockReturnValue(mockUserDataPath);
    mockedPath.join.mockReturnValue(mockSettingsPath);

    // Set up console spy
    consoleSpy = jest.spyOn(console, 'error').mockImplementation();
  });

  afterEach(() => {
    consoleSpy.mockRestore();
  });

  describe('Constructor', () => {
    it('should initialize with default settings when no file exists', () => {
      mockedFs.existsSync.mockReturnValue(false);

      store = new Store();

      expect(mockApp.getPath).toHaveBeenCalledWith('userData');
      expect(mockedPath.join).toHaveBeenCalledWith(mockUserDataPath, 'settings.json');
      expect(mockedFs.existsSync).toHaveBeenCalledWith(mockSettingsPath);

      // Verify default settings
      expect(store.get('autoDnsEnabled')).toBe(false);
      expect(store.get('httpsMode')).toBe(null);
      expect(store.get('firstLaunchCompleted')).toBe(false);
      expect(store.get('theme')).toBe('system');
      expect(store.get('openWebsiteWindows')).toEqual([]);
    });

    it('should load existing settings from file', () => {
      const existingSettings: AppSettings = {
        autoDnsEnabled: true,
        httpsMode: 'https',
        firstLaunchCompleted: true,
        theme: 'dark',
        openWebsiteWindows: [
          {
            websiteName: 'test-site',
            websitePath: '/path/to/test',
            bounds: { x: 100, y: 100, width: 800, height: 600 },
            isMaximized: false,
          },
        ],
      };

      mockedFs.existsSync.mockReturnValue(true);
      mockedFs.readFileSync.mockReturnValue(JSON.stringify(existingSettings));

      store = new Store();

      expect(mockedFs.readFileSync).toHaveBeenCalledWith(mockSettingsPath, 'utf-8');
      expect(store.get('autoDnsEnabled')).toBe(true);
      expect(store.get('httpsMode')).toBe('https');
      expect(store.get('firstLaunchCompleted')).toBe(true);
      expect(store.get('theme')).toBe('dark');
      expect(store.get('openWebsiteWindows')).toHaveLength(1);
    });

    it('should use defaults when file exists but is corrupted', () => {
      mockedFs.existsSync.mockReturnValue(true);
      mockedFs.readFileSync.mockReturnValue('invalid json');

      store = new Store();

      expect(consoleSpy).toHaveBeenCalledWith('Error reading settings file:', expect.any(Error));
      expect(store.get('autoDnsEnabled')).toBe(false);
      expect(store.get('theme')).toBe('system');
    });

    it('should use defaults when readFileSync throws error', () => {
      mockedFs.existsSync.mockReturnValue(true);
      mockedFs.readFileSync.mockImplementation(() => {
        throw new Error('Permission denied');
      });

      store = new Store();

      expect(consoleSpy).toHaveBeenCalledWith('Error reading settings file:', expect.any(Error));
      expect(store.get('autoDnsEnabled')).toBe(false);
    });
  });

  describe('get method', () => {
    beforeEach(() => {
      mockedFs.existsSync.mockReturnValue(false);
      store = new Store();
    });

    it('should return correct values for all setting keys', () => {
      expect(store.get('autoDnsEnabled')).toBe(false);
      expect(store.get('httpsMode')).toBe(null);
      expect(store.get('firstLaunchCompleted')).toBe(false);
      expect(store.get('theme')).toBe('system');
      expect(store.get('openWebsiteWindows')).toEqual([]);
    });

    it('should return updated values after set', () => {
      store.set('autoDnsEnabled', true);
      store.set('theme', 'dark');

      expect(store.get('autoDnsEnabled')).toBe(true);
      expect(store.get('theme')).toBe('dark');
    });
  });

  describe('set method', () => {
    beforeEach(() => {
      mockedFs.existsSync.mockReturnValue(false);
      store = new Store();
      jest.clearAllMocks(); // Clear the constructor calls
    });

    it('should update setting and save to disk', () => {
      store.set('autoDnsEnabled', true);

      expect(store.get('autoDnsEnabled')).toBe(true);
      expect(mockedFs.writeFileSync).toHaveBeenCalledWith(
        mockSettingsPath,
        expect.stringContaining('"autoDnsEnabled": true')
      );
    });

    it('should handle different data types correctly', () => {
      store.set('httpsMode', 'https');
      store.set('firstLaunchCompleted', true);
      store.set('theme', 'light');

      expect(store.get('httpsMode')).toBe('https');
      expect(store.get('firstLaunchCompleted')).toBe(true);
      expect(store.get('theme')).toBe('light');
      expect(mockedFs.writeFileSync).toHaveBeenCalledTimes(3);
    });

    it('should handle array data correctly', () => {
      const windowStates: WindowState[] = [
        {
          websiteName: 'site1',
          bounds: { x: 0, y: 0, width: 800, height: 600 },
          isMaximized: false,
        },
        {
          websiteName: 'site2',
          websitePath: '/path/to/site2',
          bounds: { x: 100, y: 100, width: 900, height: 700 },
          isMaximized: true,
        },
      ];

      store.set('openWebsiteWindows', windowStates);

      expect(store.get('openWebsiteWindows')).toEqual(windowStates);
      expect(store.get('openWebsiteWindows')).toHaveLength(2);
    });

    it('should handle save errors gracefully', () => {
      mockedFs.writeFileSync.mockImplementation(() => {
        throw new Error('Disk full');
      });

      store.set('autoDnsEnabled', true);

      expect(consoleSpy).toHaveBeenCalledWith('Error saving settings:', expect.any(Error));
      expect(store.get('autoDnsEnabled')).toBe(true); // Setting should still be updated in memory
    });
  });

  describe('getAll method', () => {
    beforeEach(() => {
      mockedFs.existsSync.mockReturnValue(false);
      store = new Store();
    });

    it('should return complete settings object', () => {
      const allSettings = store.getAll();

      expect(allSettings).toEqual({
        autoDnsEnabled: false,
        httpsMode: null,
        firstLaunchCompleted: false,
        theme: 'system',
        openWebsiteWindows: [],
      });
    });

    it('should return updated settings after modifications', () => {
      store.set('autoDnsEnabled', true);
      store.set('theme', 'dark');

      const allSettings = store.getAll();

      expect(allSettings.autoDnsEnabled).toBe(true);
      expect(allSettings.theme).toBe('dark');
      expect(allSettings.firstLaunchCompleted).toBe(false); // Unchanged
    });
  });

  describe('setAll method', () => {
    beforeEach(() => {
      mockedFs.existsSync.mockReturnValue(false);
      store = new Store();
      jest.clearAllMocks(); // Clear the constructor calls
    });

    it('should update multiple settings at once', () => {
      const updates: Partial<AppSettings> = {
        autoDnsEnabled: true,
        theme: 'dark',
        firstLaunchCompleted: true,
      };

      store.setAll(updates);

      expect(store.get('autoDnsEnabled')).toBe(true);
      expect(store.get('theme')).toBe('dark');
      expect(store.get('firstLaunchCompleted')).toBe(true);
      expect(mockedFs.writeFileSync).toHaveBeenCalledTimes(1);
    });

    it('should preserve existing settings not being updated', () => {
      store.set('autoDnsEnabled', true);

      jest.clearAllMocks();

      store.setAll({ theme: 'light' });

      expect(store.get('autoDnsEnabled')).toBe(true); // Preserved
      expect(store.get('theme')).toBe('light'); // Updated
    });

    it('should handle empty updates', () => {
      const originalSettings = store.getAll();

      store.setAll({});

      expect(store.getAll()).toEqual(originalSettings);
      expect(mockedFs.writeFileSync).toHaveBeenCalledTimes(1);
    });
  });

  describe('Window state management', () => {
    beforeEach(() => {
      mockedFs.existsSync.mockReturnValue(false);
      store = new Store();
      jest.clearAllMocks();
    });

    describe('saveWindowStates', () => {
      it('should save window states array', () => {
        const windowStates: WindowState[] = [
          {
            websiteName: 'site1',
            websitePath: '/path/to/site1',
            bounds: { x: 0, y: 0, width: 800, height: 600 },
            isMaximized: false,
          },
          {
            websiteName: 'site2',
            bounds: { x: 100, y: 100, width: 900, height: 700 },
            isMaximized: true,
          },
        ];

        store.saveWindowStates(windowStates);

        expect(store.get('openWebsiteWindows')).toEqual(windowStates);
        expect(mockedFs.writeFileSync).toHaveBeenCalledTimes(1);
      });

      it('should handle empty window states', () => {
        store.saveWindowStates([]);

        expect(store.get('openWebsiteWindows')).toEqual([]);
      });
    });

    describe('getWindowStates', () => {
      it('should return saved window states', () => {
        const windowStates: WindowState[] = [
          {
            websiteName: 'test-site',
            websitePath: '/test/path',
            bounds: { x: 50, y: 50, width: 1000, height: 800 },
            isMaximized: false,
          },
        ];

        store.saveWindowStates(windowStates);

        expect(store.getWindowStates()).toEqual(windowStates);
      });

      it('should return empty array by default', () => {
        expect(store.getWindowStates()).toEqual([]);
      });
    });

    describe('clearWindowStates', () => {
      it('should clear all window states', () => {
        const windowStates: WindowState[] = [
          {
            websiteName: 'site1',
            bounds: { x: 0, y: 0, width: 800, height: 600 },
          },
          {
            websiteName: 'site2',
            bounds: { x: 100, y: 100, width: 900, height: 700 },
          },
        ];

        store.saveWindowStates(windowStates);
        expect(store.getWindowStates()).toHaveLength(2);

        jest.clearAllMocks();

        store.clearWindowStates();

        expect(store.getWindowStates()).toEqual([]);
        expect(mockedFs.writeFileSync).toHaveBeenCalledTimes(1);
      });
    });
  });

  describe('Type safety', () => {
    beforeEach(() => {
      mockedFs.existsSync.mockReturnValue(false);
      store = new Store();
    });

    it('should maintain type safety for all setting keys', () => {
      // These should all compile without TypeScript errors
      const autoDns: boolean = store.get('autoDnsEnabled');
      const httpsMode: 'https' | 'http' | null = store.get('httpsMode');
      const firstLaunch: boolean = store.get('firstLaunchCompleted');
      const theme: 'system' | 'light' | 'dark' = store.get('theme');
      const windows: WindowState[] = store.get('openWebsiteWindows');

      expect(typeof autoDns).toBe('boolean');
      expect(httpsMode === null || typeof httpsMode === 'string').toBe(true);
      expect(typeof firstLaunch).toBe('boolean');
      expect(typeof theme).toBe('string');
      expect(Array.isArray(windows)).toBe(true);
    });

    it('should enforce correct types when setting values', () => {
      // These should all work
      store.set('autoDnsEnabled', true);
      store.set('httpsMode', 'https');
      store.set('httpsMode', 'http');
      store.set('httpsMode', null);
      store.set('firstLaunchCompleted', false);
      store.set('theme', 'system');
      store.set('theme', 'light');
      store.set('theme', 'dark');
      store.set('openWebsiteWindows', []);

      expect(store.get('autoDnsEnabled')).toBe(true);
      expect(store.get('httpsMode')).toBe(null);
      expect(store.get('theme')).toBe('dark');
    });
  });

  describe('JSON serialization', () => {
    beforeEach(() => {
      mockedFs.existsSync.mockReturnValue(false);
      store = new Store();
      jest.clearAllMocks();
    });

    it('should save properly formatted JSON', () => {
      store.set('autoDnsEnabled', true);
      store.set('theme', 'dark');

      expect(mockedFs.writeFileSync).toHaveBeenCalledWith(
        mockSettingsPath,
        expect.stringMatching(/\{\s*\n.*"autoDnsEnabled":\s*true.*\n.*"theme":\s*"dark".*\n.*\}/s)
      );
    });

    it('should handle complex window state objects', () => {
      const complexWindowState: WindowState = {
        websiteName: 'complex-site',
        websitePath: '/very/long/path/to/website/directory',
        bounds: {
          x: 123,
          y: 456,
          width: 1920,
          height: 1080,
        },
        isMaximized: true,
      };

      store.saveWindowStates([complexWindowState]);

      const savedJson = mockedFs.writeFileSync.mock.calls[0][1] as string;
      const parsedData = JSON.parse(savedJson);

      expect(parsedData.openWebsiteWindows).toHaveLength(1);
      expect(parsedData.openWebsiteWindows[0]).toEqual(complexWindowState);
    });
  });

  describe('Edge cases and error handling', () => {
    it('should handle undefined userData path', () => {
      mockApp.getPath.mockReturnValue(undefined);
      mockedPath.join.mockReturnValue('undefined/settings.json');
      mockedFs.existsSync.mockReturnValue(false);

      expect(() => new Store()).not.toThrow();
    });

    it('should handle JSON file containing null', () => {
      mockedFs.existsSync.mockReturnValue(true);
      mockedFs.readFileSync.mockReturnValue('null'); // Valid JSON that parses to null

      // The Store constructor handles this by setting this.data = null
      // Then accessing this.data[key] throws when trying to get settings
      store = new Store();

      // The store was created but accessing properties will fail
      expect(() => store.get('theme')).toThrow();
    });

    it('should handle empty file content', () => {
      mockedFs.existsSync.mockReturnValue(true);
      mockedFs.readFileSync.mockReturnValue('');

      store = new Store();

      expect(consoleSpy).toHaveBeenCalledWith('Error reading settings file:', expect.any(Error));
      expect(store.get('theme')).toBe('system'); // Should use defaults
    });

    it('should handle partial settings file', () => {
      const partialSettings = {
        autoDnsEnabled: true,
        theme: 'dark',
        // Missing other required fields
      };

      mockedFs.existsSync.mockReturnValue(true);
      mockedFs.readFileSync.mockReturnValue(JSON.stringify(partialSettings));

      store = new Store();

      expect(store.get('autoDnsEnabled')).toBe(true);
      expect(store.get('theme')).toBe('dark');
      // Missing fields should be undefined (not defaults) - this tests actual behavior
      expect(store.get('firstLaunchCompleted')).toBeUndefined();
    });
  });

  describe('Integration scenarios', () => {
    it('should support complete app lifecycle', () => {
      // Simulate app startup with no existing settings
      mockedFs.existsSync.mockReturnValue(false);
      store = new Store();

      // First launch setup
      expect(store.get('firstLaunchCompleted')).toBe(false);
      store.set('firstLaunchCompleted', true);
      store.set('httpsMode', 'https');
      store.set('theme', 'dark');

      // Save some window states
      const windowStates: WindowState[] = [
        {
          websiteName: 'project1',
          websitePath: '/projects/project1',
          bounds: { x: 100, y: 100, width: 1200, height: 800 },
          isMaximized: false,
        },
        {
          websiteName: 'project2',
          websitePath: '/projects/project2',
          bounds: { x: 200, y: 200, width: 1400, height: 900 },
          isMaximized: true,
        },
      ];
      store.saveWindowStates(windowStates);

      // Verify everything is saved correctly
      expect(mockedFs.writeFileSync).toHaveBeenCalledTimes(4); // 3 sets + 1 saveWindowStates

      // Simulate app restart - create new store instance that loads from file
      jest.clearAllMocks();
      mockedFs.existsSync.mockReturnValue(true);
      mockedFs.readFileSync.mockReturnValue(
        JSON.stringify({
          autoDnsEnabled: false,
          httpsMode: 'https',
          firstLaunchCompleted: true,
          theme: 'dark',
          openWebsiteWindows: windowStates,
        })
      );

      const newStore = new Store();

      // Verify settings were restored
      expect(newStore.get('firstLaunchCompleted')).toBe(true);
      expect(newStore.get('httpsMode')).toBe('https');
      expect(newStore.get('theme')).toBe('dark');
      expect(newStore.getWindowStates()).toEqual(windowStates);
      expect(newStore.getWindowStates()).toHaveLength(2);
    });
  });
});
