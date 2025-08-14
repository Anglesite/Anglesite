/**
 * @file Comprehensive tests for Store recent websites functionality (new code)
 * Targeting 90% coverage for recent websites features
 */

import * as fs from 'fs';
import * as path from 'path';

// Mock electron and file system
jest.mock('electron', () => ({
  app: {
    getPath: jest.fn(() => '/mock/user/data'),
  },
}));

jest.mock('fs');
const mockFs = fs as jest.Mocked<typeof fs>;

jest.mock('path');
const mockPath = path as jest.Mocked<typeof path>;

// Import after mocking
import { Store } from '../../app/store';

describe('Store Recent Websites (New Code)', () => {
  let store: Store;
  const mockSettingsPath = '/mock/user/data/settings.json';

  beforeEach(() => {
    jest.clearAllMocks();
    mockPath.join.mockReturnValue(mockSettingsPath);
    mockFs.existsSync.mockReturnValue(false); // Start with no existing file
  });

  describe('Recent Websites Management', () => {
    beforeEach(() => {
      store = new Store();
    });

    it('should start with empty recent websites list', () => {
      expect(store.getRecentWebsites()).toEqual([]);
    });

    it('should add a website to recent list', () => {
      store.addRecentWebsite('my-blog');

      expect(store.getRecentWebsites()).toEqual(['my-blog']);
    });

    it('should add multiple websites in order', () => {
      store.addRecentWebsite('blog');
      store.addRecentWebsite('portfolio');
      store.addRecentWebsite('docs');

      expect(store.getRecentWebsites()).toEqual(['docs', 'portfolio', 'blog']);
    });

    it('should move existing website to front when re-added', () => {
      store.addRecentWebsite('blog');
      store.addRecentWebsite('portfolio');
      store.addRecentWebsite('docs');
      store.addRecentWebsite('blog'); // Re-add existing

      expect(store.getRecentWebsites()).toEqual(['blog', 'docs', 'portfolio']);
    });

    it('should limit recent websites to maximum of 10', () => {
      // Add 12 websites
      for (let i = 1; i <= 12; i++) {
        store.addRecentWebsite(`website-${i}`);
      }

      const recentWebsites = store.getRecentWebsites();
      expect(recentWebsites).toHaveLength(10);
      expect(recentWebsites[0]).toBe('website-12'); // Most recent first
      expect(recentWebsites[9]).toBe('website-3'); // Oldest kept
      expect(recentWebsites).not.toContain('website-1'); // Oldest removed
      expect(recentWebsites).not.toContain('website-2'); // Second oldest removed
    });

    it('should remove a website from recent list', () => {
      store.addRecentWebsite('blog');
      store.addRecentWebsite('portfolio');
      store.addRecentWebsite('docs');

      store.removeRecentWebsite('portfolio');

      expect(store.getRecentWebsites()).toEqual(['docs', 'blog']);
    });

    it('should handle removing non-existent website gracefully', () => {
      store.addRecentWebsite('blog');
      store.addRecentWebsite('portfolio');

      store.removeRecentWebsite('non-existent');

      expect(store.getRecentWebsites()).toEqual(['portfolio', 'blog']);
    });

    it('should clear all recent websites', () => {
      store.addRecentWebsite('blog');
      store.addRecentWebsite('portfolio');
      store.addRecentWebsite('docs');

      store.clearRecentWebsites();

      expect(store.getRecentWebsites()).toEqual([]);
    });

    it('should persist recent websites automatically when adding', () => {
      store.addRecentWebsite('blog');

      // Should have called writeFileSync at least once
      expect(mockFs.writeFileSync).toHaveBeenCalled();
    });
  });

  describe('Loading Recent Websites from File', () => {
    it('should load recent websites from existing settings file', () => {
      const existingSettings = {
        autoDnsEnabled: false,
        httpsMode: null,
        firstLaunchCompleted: false,
        theme: 'system',
        recentWebsites: ['loaded-blog', 'loaded-portfolio'],
        openWebsiteWindows: [],
      };

      mockFs.existsSync.mockReturnValue(true);
      mockFs.readFileSync.mockReturnValue(JSON.stringify(existingSettings));

      store = new Store();

      expect(store.getRecentWebsites()).toEqual(['loaded-blog', 'loaded-portfolio']);
    });

    it('should handle missing recentWebsites property in existing file', () => {
      const existingSettings = {
        autoDnsEnabled: false,
        httpsMode: null,
        firstLaunchCompleted: false,
        theme: 'system',
        openWebsiteWindows: [],
        // Missing recentWebsites property - will be undefined
      };

      mockFs.existsSync.mockReturnValue(true);
      mockFs.readFileSync.mockReturnValue(JSON.stringify(existingSettings));

      store = new Store();

      // Store will return undefined if property is missing, not empty array
      expect(store.getRecentWebsites()).toBeUndefined();
    });

    it('should handle corrupted recentWebsites property', () => {
      const existingSettings = {
        autoDnsEnabled: false,
        httpsMode: null,
        firstLaunchCompleted: false,
        theme: 'system',
        recentWebsites: 'not-an-array', // Corrupted data
        openWebsiteWindows: [],
      };

      mockFs.existsSync.mockReturnValue(true);
      mockFs.readFileSync.mockReturnValue(JSON.stringify(existingSettings));

      store = new Store();

      // Store will return the corrupted data as-is
      expect(store.getRecentWebsites()).toBe('not-an-array');
    });
  });

  describe('Error Handling', () => {
    beforeEach(() => {
      store = new Store();
    });

    it('should handle file write errors gracefully when adding recent website', () => {
      const consoleSpy = jest.spyOn(console, 'error').mockImplementation();
      mockFs.writeFileSync.mockImplementation(() => {
        throw new Error('Disk full');
      });

      // Should not throw
      expect(() => {
        store.addRecentWebsite('test-site');
      }).not.toThrow();

      consoleSpy.mockRestore();
    });

    it('should accept any string as website name including empty strings', () => {
      // The current implementation doesn't validate, it accepts any string
      store.addRecentWebsite('');
      expect(store.getRecentWebsites()).toEqual(['']);

      // Test whitespace-only
      store.addRecentWebsite('   ');
      expect(store.getRecentWebsites()).toEqual(['   ', '']);

      // Test valid name
      store.addRecentWebsite('valid-site');
      expect(store.getRecentWebsites()).toEqual(['valid-site', '   ', '']);
    });
  });

  describe('Integration with Other Store Features', () => {
    beforeEach(() => {
      store = new Store();
    });

    it('should include recent websites in getAll() response', () => {
      store.addRecentWebsite('blog');
      store.addRecentWebsite('portfolio');

      const allSettings = store.getAll();

      expect(allSettings.recentWebsites).toEqual(['portfolio', 'blog']);
    });

    it('should preserve other settings when manipulating recent websites', () => {
      store.set('theme', 'dark');
      store.set('autoDnsEnabled', true);

      store.addRecentWebsite('test-site');

      expect(store.get('theme')).toBe('dark');
      expect(store.get('autoDnsEnabled')).toBe(true);
      expect(store.getRecentWebsites()).toEqual(['test-site']);
    });

    it('should work with setAll method', () => {
      store.setAll({
        theme: 'dark',
        recentWebsites: ['pre-existing-site'],
        autoDnsEnabled: true,
      });

      expect(store.get('theme')).toBe('dark');
      expect(store.getRecentWebsites()).toEqual(['pre-existing-site']);
      expect(store.get('autoDnsEnabled')).toBe(true);
      expect(mockFs.writeFileSync).toHaveBeenCalled();
    });

    it('should work with window state methods', () => {
      const windowStates = [
        {
          websiteName: 'test-site',
          websitePath: '/path/to/site',
          bounds: { x: 0, y: 0, width: 800, height: 600 },
          isMaximized: false,
        },
      ];

      store.saveWindowStates(windowStates);
      expect(store.getWindowStates()).toEqual(windowStates);

      store.clearWindowStates();
      expect(store.getWindowStates()).toEqual([]);
    });

    it('should handle file read errors gracefully', () => {
      const consoleSpy = jest.spyOn(console, 'error').mockImplementation();
      mockFs.existsSync.mockReturnValue(true);
      mockFs.readFileSync.mockImplementation(() => {
        throw new Error('File read error');
      });

      // Should not throw and use defaults
      const newStore = new Store();
      expect(newStore.getRecentWebsites()).toEqual([]);

      consoleSpy.mockRestore();
    });
  });
});
