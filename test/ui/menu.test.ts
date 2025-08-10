/**
 * @file Tests for menu creation and window management
 */
import type { MenuItemConstructorOptions, Menu, MenuItem, KeyboardEvent } from 'electron';

// Mock electron modules
const mockBrowserWindow = {
  getFocusedWindow: jest.fn(),
};

const mockMenu = {
  buildFromTemplate: jest.fn(),
  setApplicationMenu: jest.fn(),
};

const mockShell = {
  openExternal: jest.fn(),
};

const mockClipboard = {
  writeText: jest.fn(),
};

jest.mock('electron', () => ({
  Menu: mockMenu,
  BrowserWindow: mockBrowserWindow,
  shell: mockShell,
  clipboard: mockClipboard,
}));

// Mock UI modules
const mockHelpWindow = {
  getTitle: jest.fn(),
  focus: jest.fn(),
  isDestroyed: jest.fn(() => false),
};

const mockWebsiteWindow1 = {
  window: {
    getTitle: jest.fn(),
    focus: jest.fn(),
    isDestroyed: jest.fn(() => false),
  },
  webContentsView: {},
  websiteName: 'Test Site 1',
};

const mockWebsiteWindow2 = {
  window: {
    getTitle: jest.fn(),
    focus: jest.fn(),
    isDestroyed: jest.fn(() => false),
  },
  webContentsView: {},
  websiteName: 'Test Site 2',
};

jest.mock('../../app/ui/multi-window-manager', () => ({
  getHelpWindow: jest.fn(),
  getAllWebsiteWindows: jest.fn(),
  createHelpWindow: jest.fn(),
}));

jest.mock('../../app/ui/window-manager', () => ({
  openSettingsWindow: jest.fn(),
  openWebsiteSelectionWindow: jest.fn(),
}));

jest.mock('../../app/server/eleventy', () => ({
  getCurrentLiveServerUrl: jest.fn(() => 'https://localhost:8080'),
}));

describe('Menu', () => {
  let menu: {
    buildWindowList: () => MenuItemConstructorOptions[];
    updateApplicationMenu: () => void;
    createApplicationMenu: () => Menu;
  };
  let mockMultiWindowManager: {
    getHelpWindow: jest.Mock;
    getAllWebsiteWindows: jest.Mock;
  };

  beforeAll(() => {
    menu = require('../../app/ui/menu');
    mockMultiWindowManager = require('../../app/ui/multi-window-manager');
  });

  beforeEach(() => {
    jest.clearAllMocks();
  });

  describe('buildWindowList', () => {
    it('should return empty list when no windows are open', () => {
      mockMultiWindowManager.getHelpWindow.mockReturnValue(null);
      mockMultiWindowManager.getAllWebsiteWindows.mockReturnValue(new Map());
      mockBrowserWindow.getFocusedWindow.mockReturnValue(null);

      const windowList = menu.buildWindowList();

      expect(windowList).toEqual([
        {
          label: 'No Windows Open',
          enabled: false,
        },
      ]);
    });

    it('should include help window when it exists', () => {
      mockHelpWindow.getTitle.mockReturnValue('Anglesite');
      mockMultiWindowManager.getHelpWindow.mockReturnValue(mockHelpWindow);
      mockMultiWindowManager.getAllWebsiteWindows.mockReturnValue(new Map());
      mockBrowserWindow.getFocusedWindow.mockReturnValue(mockHelpWindow);

      const windowList = menu.buildWindowList();

      expect(windowList).toHaveLength(1);
      expect(windowList[0]).toEqual({
        label: 'Anglesite',
        type: 'checkbox',
        checked: true,
        click: expect.any(Function),
      });

      // Test click handler
      if (windowList[0].click) {
        windowList[0].click({} as MenuItem, undefined, {} as KeyboardEvent);
      }
      expect(mockHelpWindow.focus).toHaveBeenCalled();
    });

    it('should include website windows', () => {
      mockMultiWindowManager.getHelpWindow.mockReturnValue(null);

      mockWebsiteWindow1.window.getTitle.mockReturnValue('My Blog');
      mockWebsiteWindow2.window.getTitle.mockReturnValue('Portfolio');

      const websiteWindows = new Map([
        ['site1', mockWebsiteWindow1],
        ['site2', mockWebsiteWindow2],
      ]);

      mockMultiWindowManager.getAllWebsiteWindows.mockReturnValue(websiteWindows);
      mockBrowserWindow.getFocusedWindow.mockReturnValue(mockWebsiteWindow1.window);

      const windowList = menu.buildWindowList();

      expect(windowList).toHaveLength(2);

      // First window should be checked (focused)
      expect(windowList[0]).toEqual({
        label: 'My Blog',
        type: 'checkbox',
        checked: true,
        click: expect.any(Function),
      });

      // Second window should not be checked
      expect(windowList[1]).toEqual({
        label: 'Portfolio',
        type: 'checkbox',
        checked: false,
        click: expect.any(Function),
      });

      // Test click handlers
      if (windowList[0].click) {
        windowList[0].click({} as MenuItem, undefined, {} as KeyboardEvent);
      }
      expect(mockWebsiteWindow1.window.focus).toHaveBeenCalled();

      if (windowList[1].click) {
        windowList[1].click({} as MenuItem, undefined, {} as KeyboardEvent);
      }
      expect(mockWebsiteWindow2.window.focus).toHaveBeenCalled();
    });

    it('should include both help window and website windows', () => {
      mockHelpWindow.getTitle.mockReturnValue('Anglesite');
      mockMultiWindowManager.getHelpWindow.mockReturnValue(mockHelpWindow);

      mockWebsiteWindow1.window.getTitle.mockReturnValue('My Blog');
      const websiteWindows = new Map([['site1', mockWebsiteWindow1]]);
      mockMultiWindowManager.getAllWebsiteWindows.mockReturnValue(websiteWindows);

      mockBrowserWindow.getFocusedWindow.mockReturnValue(mockWebsiteWindow1.window);

      const windowList = menu.buildWindowList();

      expect(windowList).toHaveLength(2);

      // Help window should not be checked
      expect(windowList[0]).toEqual({
        label: 'Anglesite',
        type: 'checkbox',
        checked: false,
        click: expect.any(Function),
      });

      // Website window should be checked (focused)
      expect(windowList[1]).toEqual({
        label: 'My Blog',
        type: 'checkbox',
        checked: true,
        click: expect.any(Function),
      });
    });

    it('should skip destroyed windows', () => {
      mockHelpWindow.isDestroyed.mockReturnValue(true);
      mockMultiWindowManager.getHelpWindow.mockReturnValue(mockHelpWindow);

      mockWebsiteWindow1.window.isDestroyed.mockReturnValue(true);
      const websiteWindows = new Map([['site1', mockWebsiteWindow1]]);
      mockMultiWindowManager.getAllWebsiteWindows.mockReturnValue(websiteWindows);

      mockBrowserWindow.getFocusedWindow.mockReturnValue(null);

      const windowList = menu.buildWindowList();

      expect(windowList).toEqual([
        {
          label: 'No Windows Open',
          enabled: false,
        },
      ]);
    });

    it('should handle no focused window', () => {
      mockHelpWindow.getTitle.mockReturnValue('Anglesite');
      mockHelpWindow.isDestroyed.mockReturnValue(false); // Make sure it's not destroyed
      mockMultiWindowManager.getHelpWindow.mockReturnValue(mockHelpWindow);
      mockMultiWindowManager.getAllWebsiteWindows.mockReturnValue(new Map());
      mockBrowserWindow.getFocusedWindow.mockReturnValue(null);

      const windowList = menu.buildWindowList();

      expect(windowList).toHaveLength(1);
      expect(windowList[0]).toEqual({
        label: 'Anglesite',
        type: 'checkbox',
        checked: false,
        click: expect.any(Function),
      });
    });
  });

  describe('updateApplicationMenu', () => {
    it('should build and set application menu', () => {
      const mockMenuInstance = { items: [] };
      mockMenu.buildFromTemplate.mockReturnValue(mockMenuInstance);

      menu.updateApplicationMenu();

      expect(mockMenu.buildFromTemplate).toHaveBeenCalledWith(expect.any(Array));
      expect(mockMenu.setApplicationMenu).toHaveBeenCalledWith(mockMenuInstance);
    });
  });

  describe('createApplicationMenu', () => {
    it('should create menu template with window list', () => {
      mockMultiWindowManager.getHelpWindow.mockReturnValue(null);
      mockMultiWindowManager.getAllWebsiteWindows.mockReturnValue(new Map());

      menu.createApplicationMenu();

      expect(mockMenu.buildFromTemplate).toHaveBeenCalledWith(expect.any(Array));

      // Get the template that was passed to buildFromTemplate
      const template = mockMenu.buildFromTemplate.mock.calls[0][0] as MenuItemConstructorOptions[];

      // Find the Window menu
      const windowMenu = template.find((item) => item.label === 'Window');
      expect(windowMenu).toBeDefined();
      expect(windowMenu?.submenu).toEqual(
        expect.arrayContaining([
          expect.objectContaining({ label: 'Minimize' }),
          expect.objectContaining({ label: 'Close' }),
          expect.objectContaining({ label: 'Bring All to Front' }),
          expect.objectContaining({ type: 'separator' }),
          expect.objectContaining({ label: 'No Windows Open', enabled: false }),
        ])
      );
    });

    it('should include window items in Window menu when windows exist', () => {
      mockHelpWindow.getTitle.mockReturnValue('Anglesite');
      mockHelpWindow.isDestroyed.mockReturnValue(false);
      mockMultiWindowManager.getHelpWindow.mockReturnValue(mockHelpWindow);
      mockMultiWindowManager.getAllWebsiteWindows.mockReturnValue(new Map());
      mockBrowserWindow.getFocusedWindow.mockReturnValue(mockHelpWindow);

      menu.createApplicationMenu();

      const template = mockMenu.buildFromTemplate.mock.calls[0][0] as MenuItemConstructorOptions[];
      const windowMenu = template.find((item) => item.label === 'Window');

      // Check that the window list includes the help window
      const windowSubmenu = windowMenu?.submenu as MenuItemConstructorOptions[];
      const helpWindowItem = windowSubmenu.find((item) => item.label === 'Anglesite' && item.type === 'checkbox');

      expect(helpWindowItem).toBeDefined();
      expect(helpWindowItem?.checked).toBe(true);
    });
  });
});
