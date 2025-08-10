/**
 * @file Tests for window management and DevTools functionality
 */

// Mock Electron modules
const mockBrowserWindow = {
  getFocusedWindow: jest.fn(),
  getAllWindows: jest.fn(() => []),
};

const mockWebContents = {
  isDevToolsOpened: jest.fn(),
  openDevTools: jest.fn(),
  closeDevTools: jest.fn(),
};

const mockWebContentsView = {
  webContents: mockWebContents,
};

const mockHelpWindow = {
  contentView: {
    children: [mockWebContentsView],
  },
};

const mockWebsiteWindow = {
  window: {},
  webContentsView: mockWebContentsView,
  websiteName: 'test-site',
};

const mockMultiWindowManager = {
  getHelpWindow: jest.fn(),
  getAllWebsiteWindows: jest.fn(),
};

// Set up mocks
jest.mock('electron', () => ({
  BrowserWindow: mockBrowserWindow,
  app: {
    getPath: jest.fn(() => '/mock/path'),
  },
  nativeTheme: {
    shouldUseDarkColors: false,
    on: jest.fn(),
  },
  ipcMain: {
    handle: jest.fn(),
    on: jest.fn(),
  },
}));

jest.mock('../../app/ui/multi-window-manager', () => mockMultiWindowManager);

describe('Window Manager', () => {
  let windowManager: typeof import('../../app/ui/window-manager');

  beforeAll(() => {
    // Import after mocks are set up
    windowManager = require('../../app/ui/window-manager');
  });

  beforeEach(() => {
    // Reset all mocks
    jest.clearAllMocks();

    // Set up default mock implementations
    mockBrowserWindow.getFocusedWindow.mockReturnValue(mockHelpWindow);
    mockMultiWindowManager.getHelpWindow.mockReturnValue(mockHelpWindow);
    mockMultiWindowManager.getAllWebsiteWindows.mockReturnValue(new Map());
    mockWebContents.isDevToolsOpened.mockReturnValue(false);
  });

  describe('togglePreviewDevTools', () => {
    it('should handle no focused window', () => {
      mockBrowserWindow.getFocusedWindow.mockReturnValue(null);

      const consoleSpy = jest.spyOn(console, 'log').mockImplementation();

      windowManager.togglePreviewDevTools();

      expect(consoleSpy).toHaveBeenCalledWith('No focused window found for DevTools');
      expect(mockWebContents.openDevTools).not.toHaveBeenCalled();

      consoleSpy.mockRestore();
    });

    it('should open DevTools for help window when closed', () => {
      mockWebContents.isDevToolsOpened.mockReturnValue(false);

      windowManager.togglePreviewDevTools();

      expect(mockMultiWindowManager.getHelpWindow).toHaveBeenCalled();
      expect(mockWebContents.isDevToolsOpened).toHaveBeenCalled();
      expect(mockWebContents.openDevTools).toHaveBeenCalled();
      expect(mockWebContents.closeDevTools).not.toHaveBeenCalled();
    });

    it('should close DevTools for help window when open', () => {
      mockWebContents.isDevToolsOpened.mockReturnValue(true);

      windowManager.togglePreviewDevTools();

      expect(mockMultiWindowManager.getHelpWindow).toHaveBeenCalled();
      expect(mockWebContents.isDevToolsOpened).toHaveBeenCalled();
      expect(mockWebContents.closeDevTools).toHaveBeenCalled();
      expect(mockWebContents.openDevTools).not.toHaveBeenCalled();
    });

    it('should handle help window with no WebContentsView', () => {
      const helpWindowNoViews = {
        contentView: { children: [] },
      };

      mockBrowserWindow.getFocusedWindow.mockReturnValue(helpWindowNoViews);
      mockMultiWindowManager.getHelpWindow.mockReturnValue(helpWindowNoViews);

      windowManager.togglePreviewDevTools();

      expect(mockWebContents.openDevTools).not.toHaveBeenCalled();
      expect(mockWebContents.closeDevTools).not.toHaveBeenCalled();
    });

    it('should open DevTools for website window when closed', () => {
      const mockFocusedWebsiteWindow = { id: 'test-window' };
      const websiteWindows = new Map([
        [
          'test-site',
          {
            ...mockWebsiteWindow,
            window: mockFocusedWebsiteWindow,
          },
        ],
      ]);

      mockBrowserWindow.getFocusedWindow.mockReturnValue(mockFocusedWebsiteWindow);
      mockMultiWindowManager.getHelpWindow.mockReturnValue(null);
      mockMultiWindowManager.getAllWebsiteWindows.mockReturnValue(websiteWindows);
      mockWebContents.isDevToolsOpened.mockReturnValue(false);

      windowManager.togglePreviewDevTools();

      expect(mockMultiWindowManager.getAllWebsiteWindows).toHaveBeenCalled();
      expect(mockWebContents.isDevToolsOpened).toHaveBeenCalled();
      expect(mockWebContents.openDevTools).toHaveBeenCalled();
      expect(mockWebContents.closeDevTools).not.toHaveBeenCalled();
    });

    it('should close DevTools for website window when open', () => {
      const mockFocusedWebsiteWindow = { id: 'test-window' };
      const websiteWindows = new Map([
        [
          'test-site',
          {
            ...mockWebsiteWindow,
            window: mockFocusedWebsiteWindow,
          },
        ],
      ]);

      mockBrowserWindow.getFocusedWindow.mockReturnValue(mockFocusedWebsiteWindow);
      mockMultiWindowManager.getHelpWindow.mockReturnValue(null);
      mockMultiWindowManager.getAllWebsiteWindows.mockReturnValue(websiteWindows);
      mockWebContents.isDevToolsOpened.mockReturnValue(true);

      windowManager.togglePreviewDevTools();

      expect(mockMultiWindowManager.getAllWebsiteWindows).toHaveBeenCalled();
      expect(mockWebContents.isDevToolsOpened).toHaveBeenCalled();
      expect(mockWebContents.closeDevTools).toHaveBeenCalled();
      expect(mockWebContents.openDevTools).not.toHaveBeenCalled();
    });

    it('should handle unrecognized window', () => {
      const unrecognizedWindow = { id: 'unknown-window' };
      const websiteWindows = new Map();

      mockBrowserWindow.getFocusedWindow.mockReturnValue(unrecognizedWindow);
      mockMultiWindowManager.getHelpWindow.mockReturnValue(null);
      mockMultiWindowManager.getAllWebsiteWindows.mockReturnValue(websiteWindows);

      const consoleSpy = jest.spyOn(console, 'log').mockImplementation();

      windowManager.togglePreviewDevTools();

      expect(consoleSpy).toHaveBeenCalledWith('Focused window is not a recognized Anglesite window');
      expect(mockWebContents.openDevTools).not.toHaveBeenCalled();
      expect(mockWebContents.closeDevTools).not.toHaveBeenCalled();

      consoleSpy.mockRestore();
    });
  });

  describe('Module Exports', () => {
    it('should export required functions', () => {
      expect(typeof windowManager.togglePreviewDevTools).toBe('function');
      expect(typeof windowManager.createWindow).toBe('function');
      expect(typeof windowManager.showPreview).toBe('function');
      expect(typeof windowManager.hidePreview).toBe('function');
      expect(typeof windowManager.reloadPreview).toBe('function');
    });
  });
});
