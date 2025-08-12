/**
 * @file Tests for Website Manager functionality
 */

import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';

// Mock Electron dialog module
jest.mock('electron', () => ({
  dialog: {
    showMessageBoxSync: jest.fn(),
  },
  BrowserWindow: jest.fn(),
}));

// Mock fs module
jest.mock('fs');
const mockedFs = fs as jest.Mocked<typeof fs>;

// Mock path module
jest.mock('path');
const mockedPath = path as jest.Mocked<typeof path>;

// Mock os module
jest.mock('os');
const mockedOs = os as jest.Mocked<typeof os>;

// Import after mocking
import {
  createWebsiteWithName,
  getWebsiteNameFromUser,
  validateWebsiteName,
  listWebsites,
  deleteWebsite,
  getWebsitePath,
  renameWebsite,
} from '../../app/utils/website-manager';

// Mock process.env and process.platform
const originalPlatform = process.platform;
const originalEnv = process.env;

describe('Website Manager', () => {
  let consoleSpy: jest.SpyInstance;
  let mockDialog: any;

  beforeEach(() => {
    // Reset all mocks
    jest.clearAllMocks();

    // Get the mocked dialog
    mockDialog = require('electron').dialog;

    // Set up console spy
    consoleSpy = jest.spyOn(console, 'log').mockImplementation();

    // Set up default mock implementations
    mockedOs.homedir.mockReturnValue('/mock/home');
    mockedPath.join.mockImplementation((...args) => args.join('/'));
    mockedFs.existsSync.mockReturnValue(false);

    // Reset environment
    process.env = { ...originalEnv };
  });

  afterEach(() => {
    consoleSpy.mockRestore();
    // Restore original platform
    Object.defineProperty(process, 'platform', {
      value: originalPlatform,
      configurable: true,
    });
    // Restore environment
    process.env = originalEnv;
  });

  describe('getWebsitesDirectory', () => {
    it('should return correct path for macOS', () => {
      Object.defineProperty(process, 'platform', {
        value: 'darwin',
        configurable: true,
      });

      const result = getWebsitePath('test-site');

      expect(mockedOs.homedir).toHaveBeenCalled();
      expect(mockedPath.join).toHaveBeenCalledWith('/mock/home', 'Library', 'Application Support', 'Anglesite');
      expect(mockedPath.join).toHaveBeenCalledWith('/mock/home/Library/Application Support/Anglesite', 'websites');
    });

    it('should return correct path for Windows', () => {
      Object.defineProperty(process, 'platform', {
        value: 'win32',
        configurable: true,
      });
      process.env.APPDATA = '/mock/appdata';

      getWebsitePath('test-site');

      expect(mockedPath.join).toHaveBeenCalledWith('/mock/appdata', 'Anglesite');
    });

    it('should return correct path for Linux', () => {
      Object.defineProperty(process, 'platform', {
        value: 'linux',
        configurable: true,
      });

      getWebsitePath('test-site');

      expect(mockedOs.homedir).toHaveBeenCalled();
      expect(mockedPath.join).toHaveBeenCalledWith('/mock/home', '.config', 'anglesite');
    });

    it('should handle Windows without APPDATA environment variable', () => {
      Object.defineProperty(process, 'platform', {
        value: 'win32',
        configurable: true,
      });
      delete process.env.APPDATA;

      getWebsitePath('test-site');

      expect(mockedPath.join).toHaveBeenCalledWith('', 'Anglesite');
    });
  });

  describe('createWebsiteWithName', () => {
    // Remove specific path mocks - use the default join implementation

    it('should create a new website successfully', async () => {
      mockedFs.existsSync
        .mockReturnValueOnce(false) // websites directory doesn't exist
        .mockReturnValueOnce(false); // new website doesn't exist

      const result = await createWebsiteWithName('test-site');

      // Check that directories are created
      expect(mockedFs.mkdirSync).toHaveBeenCalledTimes(2);
      expect(mockedFs.mkdirSync).toHaveBeenNthCalledWith(1, expect.stringContaining('websites'), { recursive: true });
      expect(mockedFs.mkdirSync).toHaveBeenNthCalledWith(2, expect.stringContaining('test-site'), { recursive: true });

      // Check that index.md is written
      expect(mockedFs.writeFileSync).toHaveBeenCalledWith(
        expect.stringContaining('index.md'),
        expect.stringContaining('# Welcome to test-site')
      );

      // Check return value
      expect(result).toContain('test-site');

      // Check console logs
      expect(consoleSpy).toHaveBeenCalledWith('Creating new website:', 'test-site');
    });

    it('should create website when websites directory already exists', async () => {
      mockedFs.existsSync
        .mockReturnValueOnce(true) // websites directory exists
        .mockReturnValueOnce(false); // new website doesn't exist

      await createWebsiteWithName('test-site');

      expect(mockedFs.mkdirSync).toHaveBeenCalledTimes(1); // Only for the new website, not the parent directory
      expect(mockedFs.mkdirSync).toHaveBeenCalledWith(expect.stringContaining('test-site'), { recursive: true });
    });

    it('should throw error if website already exists', async () => {
      mockedFs.existsSync
        .mockReturnValueOnce(true) // websites directory exists
        .mockReturnValueOnce(true); // new website already exists

      await expect(createWebsiteWithName('existing-site')).rejects.toThrow('Website "existing-site" already exists');

      expect(mockedFs.mkdirSync).not.toHaveBeenCalled();
      expect(mockedFs.writeFileSync).not.toHaveBeenCalled();
    });

    it('should create proper index.md content', async () => {
      mockedFs.existsSync.mockReturnValue(false);

      await createWebsiteWithName('my-blog');

      const indexContent = mockedFs.writeFileSync.mock.calls[0][1] as string;

      expect(indexContent).toContain('---');
      expect(indexContent).toContain('layout: base-layout.njk');
      expect(indexContent).toContain('title: my-blog');
      expect(indexContent).toContain('# Welcome to my-blog');
      expect(indexContent).toContain('This is your new website!');
      expect(indexContent).toContain('## Getting Started');
      expect(indexContent).toContain('Happy building! 🚀');
    });

    it('should handle special characters in website name', async () => {
      mockedFs.existsSync.mockReturnValue(false);

      await createWebsiteWithName('my_awesome-site123');

      const indexContent = mockedFs.writeFileSync.mock.calls[0][1] as string;
      expect(indexContent).toContain('title: my_awesome-site123');
      expect(indexContent).toContain('# Welcome to my_awesome-site123');
    });
  });

  describe('validateWebsiteName', () => {
    it('should accept valid website names', () => {
      const validNames = [
        'simple',
        'my-site',
        'my_site',
        'site123',
        'a',
        'site-with-numbers-123',
        'Site_With_Underscores',
        'UPPERCASE',
        'lowercase',
        'Mixed-Case_123',
      ];

      validNames.forEach((name) => {
        const result = validateWebsiteName(name);
        expect(result.valid).toBe(true);
        expect(result.error).toBeUndefined();
      });
    });

    it('should reject empty or whitespace names', () => {
      const invalidNames = ['', ' ', '   ', '\t', '\n'];

      invalidNames.forEach((name) => {
        const result = validateWebsiteName(name);
        expect(result.valid).toBe(false);
        expect(result.error).toBe('Website name cannot be empty');
      });
    });

    it('should reject names with invalid characters', () => {
      const invalidNames = [
        'site with spaces',
        'site.with.dots',
        'site@email',
        'site#hash',
        'site$money',
        'site%percent',
        'site&and',
        'site*star',
        'site+plus',
        'site=equals',
        'site[brackets]',
        'site{braces}',
        'site|pipe',
        'site\\backslash',
        'site/slash',
        'site?question',
        'site<greater>',
        'site"quotes"',
        "site'apostrophe",
        'site;semicolon',
        'site:colon',
        'site,comma',
        'site~tilde',
        'site`backtick',
      ];

      invalidNames.forEach((name) => {
        const result = validateWebsiteName(name);
        expect(result.valid).toBe(false);
        expect(result.error).toBe('Website name can only contain letters, numbers, hyphens, and underscores');
      });
    });

    it('should reject names that are too long', () => {
      const longName = 'a'.repeat(51); // 51 characters

      const result = validateWebsiteName(longName);

      expect(result.valid).toBe(false);
      expect(result.error).toBe('Website name must be 50 characters or less');
    });

    it('should accept names that are exactly 50 characters', () => {
      const maxLengthName = 'a'.repeat(50); // Exactly 50 characters

      const result = validateWebsiteName(maxLengthName);

      expect(result.valid).toBe(true);
      expect(result.error).toBeUndefined();
    });
  });

  describe('getWebsiteNameFromUser', () => {
    it('should return website name when user clicks Create', async () => {
      mockDialog.showMessageBoxSync.mockReturnValue(1); // Create button

      const result = await getWebsiteNameFromUser();

      expect(result).toBe('my-new-website');
      expect(mockDialog.showMessageBoxSync).toHaveBeenCalledWith({
        type: 'question',
        title: 'New Website',
        message: 'Enter website name:',
        buttons: ['Cancel', 'Create'],
        defaultId: 1,
        cancelId: 0,
      });
    });

    it('should return null when user clicks Cancel', async () => {
      mockDialog.showMessageBoxSync.mockReturnValue(0); // Cancel button

      const result = await getWebsiteNameFromUser();

      expect(result).toBe(null);
    });

    it('should return null when user uses escape key', async () => {
      mockDialog.showMessageBoxSync.mockReturnValue(-1); // Escape/close

      const result = await getWebsiteNameFromUser();

      expect(result).toBe(null);
    });
  });

  describe('listWebsites', () => {
    beforeEach(() => {
      mockedPath.join.mockReturnValue('/mock/websites');
    });

    it('should return empty array when websites directory does not exist', () => {
      mockedFs.existsSync.mockReturnValue(false);

      const result = listWebsites();

      expect(result).toEqual([]);
      expect(mockedFs.readdirSync).not.toHaveBeenCalled();
    });

    it('should return list of website directories', () => {
      mockedFs.existsSync.mockReturnValue(true);
      mockedFs.readdirSync.mockReturnValue([
        { name: 'site1', isDirectory: () => true },
        { name: 'site2', isDirectory: () => true },
        { name: 'file.txt', isDirectory: () => false },
        { name: 'site3', isDirectory: () => true },
      ] as any);

      const result = listWebsites();

      expect(result).toEqual(['site1', 'site2', 'site3']);
      expect(mockedFs.readdirSync).toHaveBeenCalledWith('/mock/websites', { withFileTypes: true });
    });

    it('should return empty array when no directories exist', () => {
      mockedFs.existsSync.mockReturnValue(true);
      mockedFs.readdirSync.mockReturnValue([
        { name: 'file1.txt', isDirectory: () => false },
        { name: 'file2.md', isDirectory: () => false },
      ] as any);

      const result = listWebsites();

      expect(result).toEqual([]);
    });

    it('should handle readdirSync errors gracefully', () => {
      const consoleErrorSpy = jest.spyOn(console, 'error').mockImplementation();
      mockedFs.existsSync.mockReturnValue(true);
      mockedFs.readdirSync.mockImplementation(() => {
        throw new Error('Permission denied');
      });

      const result = listWebsites();

      expect(result).toEqual([]);
      expect(consoleErrorSpy).toHaveBeenCalledWith('Failed to list websites:', expect.any(Error));

      consoleErrorSpy.mockRestore();
    });
  });

  describe('deleteWebsite', () => {
    it('should delete website when user confirms', async () => {
      mockedFs.existsSync.mockReturnValue(true);
      mockDialog.showMessageBoxSync.mockReturnValue(1); // Delete button

      const result = await deleteWebsite('test-site');

      expect(result).toBe(true);
      expect(mockDialog.showMessageBoxSync).toHaveBeenCalledWith({
        type: 'warning',
        title: 'Delete Website',
        message: 'Are you sure you want to delete "test-site"?',
        detail: 'This action cannot be undone.',
        buttons: ['Cancel', 'Delete'],
        defaultId: 0,
        cancelId: 0,
      });
      expect(mockedFs.rmSync).toHaveBeenCalledWith(expect.stringContaining('test-site'), { recursive: true });
      expect(consoleSpy).toHaveBeenCalledWith('Website deleted:', expect.stringContaining('test-site'));
    });

    it('should not delete website when user cancels', async () => {
      mockedFs.existsSync.mockReturnValue(true);
      mockDialog.showMessageBoxSync.mockReturnValue(0); // Cancel button

      const result = await deleteWebsite('test-site');

      expect(result).toBe(false);
      expect(mockedFs.rmSync).not.toHaveBeenCalled();
    });

    it('should use parent window for modal dialog', async () => {
      mockedFs.existsSync.mockReturnValue(true);
      mockDialog.showMessageBoxSync.mockReturnValue(1);
      const mockParentWindow = { id: 'mock-window' } as any;

      await deleteWebsite('test-site', mockParentWindow);

      expect(mockDialog.showMessageBoxSync).toHaveBeenCalledWith(
        mockParentWindow,
        expect.objectContaining({
          type: 'warning',
          title: 'Delete Website',
        })
      );
    });

    it('should throw error when website does not exist', async () => {
      mockedFs.existsSync.mockReturnValue(false);

      await expect(deleteWebsite('non-existent-site')).rejects.toThrow('Website "non-existent-site" does not exist');

      expect(mockDialog.showMessageBoxSync).not.toHaveBeenCalled();
      expect(mockedFs.rmSync).not.toHaveBeenCalled();
    });

    it('should handle file system errors during deletion', async () => {
      const consoleErrorSpy = jest.spyOn(console, 'error').mockImplementation();
      mockedFs.existsSync.mockReturnValue(true);
      mockDialog.showMessageBoxSync.mockReturnValue(1); // Delete button
      mockedFs.rmSync.mockImplementation(() => {
        throw new Error('Permission denied');
      });

      await expect(deleteWebsite('test-site')).rejects.toThrow('Permission denied');

      expect(consoleErrorSpy).toHaveBeenCalledWith('Failed to delete website:', expect.any(Error));
      consoleErrorSpy.mockRestore();
    });
  });

  describe('getWebsitePath', () => {
    it('should return correct website path', () => {
      const result = getWebsitePath('my-site');

      expect(result).toContain('my-site');
      expect(result).toContain('websites');
    });

    it('should handle special characters in website name', () => {
      const result = getWebsitePath('my_awesome-site123');

      expect(result).toContain('my_awesome-site123');
      expect(result).toContain('websites');
    });
  });

  describe('renameWebsite', () => {
    it('should rename website successfully', async () => {
      mockedFs.existsSync
        .mockReturnValueOnce(true) // old website exists
        .mockReturnValueOnce(false); // new website doesn't exist

      const result = await renameWebsite('old-site', 'new-site');

      expect(result).toBe(true);
      expect(mockedFs.renameSync).toHaveBeenCalledWith(
        expect.stringContaining('old-site'),
        expect.stringContaining('new-site')
      );
      expect(consoleSpy).toHaveBeenCalledWith('Renaming website from "old-site" to "new-site"');
      expect(consoleSpy).toHaveBeenCalledWith('Website renamed from "old-site" to "new-site"');
    });

    it('should validate new website name', async () => {
      await expect(renameWebsite('old-site', 'invalid name with spaces')).rejects.toThrow(
        'Website name can only contain letters, numbers, hyphens, and underscores'
      );

      expect(mockedFs.existsSync).not.toHaveBeenCalled();
      expect(mockedFs.renameSync).not.toHaveBeenCalled();
    });

    it('should throw error when old website does not exist', async () => {
      mockedFs.existsSync.mockReturnValueOnce(false); // old website doesn't exist

      await expect(renameWebsite('non-existent', 'new-site')).rejects.toThrow('Website "non-existent" does not exist');

      expect(mockedFs.renameSync).not.toHaveBeenCalled();
    });

    it('should throw error when new website name already exists', async () => {
      mockedFs.existsSync
        .mockReturnValueOnce(true) // old website exists
        .mockReturnValueOnce(true); // new website already exists

      await expect(renameWebsite('old-site', 'existing-site')).rejects.toThrow(
        'Website "existing-site" already exists'
      );

      expect(mockedFs.renameSync).not.toHaveBeenCalled();
    });

    it('should handle file system errors during rename', async () => {
      const consoleErrorSpy = jest.spyOn(console, 'error').mockImplementation();
      mockedFs.existsSync.mockReturnValueOnce(true).mockReturnValueOnce(false);
      mockedFs.renameSync.mockImplementation(() => {
        throw new Error('Permission denied');
      });

      await expect(renameWebsite('old-site', 'new-site')).rejects.toThrow('Permission denied');

      expect(consoleErrorSpy).toHaveBeenCalledWith('Failed to rename website:', expect.any(Error));
      consoleErrorSpy.mockRestore();
    });

    it('should handle empty new name validation', async () => {
      await expect(renameWebsite('old-site', '')).rejects.toThrow('Website name cannot be empty');
    });

    it('should handle name too long validation', async () => {
      const longName = 'a'.repeat(51);

      await expect(renameWebsite('old-site', longName)).rejects.toThrow('Website name must be 50 characters or less');
    });
  });

  describe('Cross-platform compatibility', () => {
    it('should handle different platforms correctly', () => {
      const platforms = ['darwin', 'win32', 'linux', 'freebsd'] as const;

      platforms.forEach((platform) => {
        Object.defineProperty(process, 'platform', {
          value: platform,
          configurable: true,
        });

        expect(() => getWebsitePath('test-site')).not.toThrow();
      });
    });

    it('should handle missing environment variables gracefully', () => {
      Object.defineProperty(process, 'platform', {
        value: 'win32',
        configurable: true,
      });
      delete process.env.APPDATA;

      expect(() => getWebsitePath('test-site')).not.toThrow();
    });
  });

  describe('Integration scenarios', () => {
    it('should support complete website lifecycle', async () => {
      // Start fresh - clear all previous mocks and implementations
      jest.resetAllMocks();

      // Reset default implementations
      mockedOs.homedir.mockReturnValue('/mock/home');
      mockedPath.join.mockImplementation((...args) => args.join('/'));

      // Setup mocks for creation
      mockedFs.existsSync.mockReturnValue(false);

      // 1. Create website
      const websitePath = await createWebsiteWithName('my-blog');
      expect(websitePath).toContain('my-blog');

      // 2. List websites (should include our new one)
      jest.clearAllMocks();
      mockedOs.homedir.mockReturnValue('/mock/home');
      mockedPath.join.mockImplementation((...args) => args.join('/'));
      mockedFs.existsSync.mockReturnValue(true);
      mockedFs.readdirSync.mockReturnValue([
        { name: 'my-blog', isDirectory: () => true },
        { name: 'other-site', isDirectory: () => true },
      ] as any);

      const websites = listWebsites();
      expect(websites).toContain('my-blog');

      // 3. Rename website
      jest.clearAllMocks();
      mockedOs.homedir.mockReturnValue('/mock/home');
      mockedPath.join.mockImplementation((...args) => args.join('/'));
      mockedFs.existsSync.mockReturnValueOnce(true).mockReturnValueOnce(false);
      // Ensure renameSync works normally
      mockedFs.renameSync.mockImplementation(() => {});

      const renamed = await renameWebsite('my-blog', 'my-awesome-blog');
      expect(renamed).toBe(true);

      // 4. Delete website
      jest.clearAllMocks();
      mockedOs.homedir.mockReturnValue('/mock/home');
      mockedPath.join.mockImplementation((...args) => args.join('/'));
      mockedFs.existsSync.mockReturnValue(true);
      mockedFs.rmSync.mockImplementation(() => {}); // Ensure rmSync works
      mockDialog.showMessageBoxSync.mockReturnValue(1); // Delete

      const deleted = await deleteWebsite('my-awesome-blog');
      expect(deleted).toBe(true);
    });

    it('should handle concurrent operations gracefully', async () => {
      // Test that multiple operations don't interfere with each other
      mockedFs.existsSync.mockReturnValue(false);

      const promises = [createWebsiteWithName('site1'), createWebsiteWithName('site2'), createWebsiteWithName('site3')];

      // All should succeed independently
      await expect(Promise.all(promises)).resolves.toHaveLength(3);
    });
  });

  describe('Error edge cases', () => {
    it('should handle undefined or null website names', () => {
      expect(validateWebsiteName(undefined as any)).toEqual({
        valid: false,
        error: 'Website name cannot be empty',
      });

      expect(validateWebsiteName(null as any)).toEqual({
        valid: false,
        error: 'Website name cannot be empty',
      });
    });

    it('should handle very long file paths', async () => {
      const longPath = '/very/long/path/that/might/cause/issues/in/some/systems';
      mockedPath.join.mockReturnValue(longPath);
      mockedFs.existsSync.mockReturnValue(false);

      // Should not throw even with long paths
      await expect(createWebsiteWithName('test')).resolves.toBeDefined();
    });

    it('should handle unicode characters in validation', () => {
      const unicodeNames = [
        'café', // accented characters
        'café-blog', // mixed
        'サイト', // Japanese
        '网站', // Chinese
        'сайт', // Cyrillic
      ];

      unicodeNames.forEach((name) => {
        const result = validateWebsiteName(name);
        expect(result.valid).toBe(false);
        expect(result.error).toBe('Website name can only contain letters, numbers, hyphens, and underscores');
      });
    });
  });
});
