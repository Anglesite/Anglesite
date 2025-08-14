/**
 * @file Test website editor IPC handlers
 */

import { ipcMain, BrowserWindow, IpcMainEvent } from 'electron';
import { setupIpcMainListeners } from '../../app/ipc/handlers';

// Mock electron app
jest.mock('electron', () => ({
  ipcMain: {
    emit: jest.fn(),
    removeAllListeners: jest.fn(),
    on: jest.fn(),
    handle: jest.fn(),
  },
  BrowserWindow: {
    fromWebContents: jest.fn(),
  },
  app: {
    getPath: jest.fn(() => '/mock/user/data'),
  },
  nativeTheme: {
    themeSource: 'system',
    shouldUseDarkColors: false,
    on: jest.fn(),
  },
  dialog: {
    showMessageBox: jest.fn(),
    showSaveDialog: jest.fn(),
  },
}));

// Mock the multi-window-manager module
jest.mock('../../app/ui/multi-window-manager', () => ({
  showWebsitePreview: jest.fn(),
  hideWebsitePreview: jest.fn(),
  getAllWebsiteWindows: jest.fn(() => new Map()),
}));

describe('Website Editor IPC Handlers', () => {
  let mockWindow: Partial<BrowserWindow>;
  let mockEvent: Partial<IpcMainEvent>;

  beforeEach(() => {
    jest.clearAllMocks();

    mockWindow = {
      isDestroyed: jest.fn(() => false),
    };

    mockEvent = {
      sender: {
        send: jest.fn(),
      } as Partial<import('electron').WebContents>,
    } as Partial<IpcMainEvent>;

    // Reset ipcMain mocks
    (ipcMain.on as jest.Mock).mockClear();
    (ipcMain.handle as jest.Mock).mockClear();

    // Set up ipcMain.on to actually register listeners for testing
    const listeners = new Map<string, (event: IpcMainEvent) => void>();
    (ipcMain.on as jest.Mock).mockImplementation((channel: string, handler: (event: IpcMainEvent) => void) => {
      listeners.set(channel, handler);
    });

    // Mock ipcMain.emit to call the registered handler
    (ipcMain.emit as jest.Mock).mockImplementation((channel: string, event: IpcMainEvent) => {
      const handler = listeners.get(channel);
      if (handler) {
        return handler(event);
      }
    });

    // Mock BrowserWindow.fromWebContents
    (BrowserWindow.fromWebContents as jest.Mock).mockReturnValue(mockWindow);

    setupIpcMainListeners();
  });

  afterEach(() => {
    ipcMain.removeAllListeners('website-editor-show-preview');
    ipcMain.removeAllListeners('website-editor-show-edit');
  });

  describe('website-editor-show-preview', () => {
    it('should call showWebsitePreview when window and website name are found', async () => {
      const { showWebsitePreview, getAllWebsiteWindows } = require('../../app/ui/multi-window-manager');

      // Set up the mock so that the window appears in the website windows map
      const mockWebsiteWindows = new Map([['test-website', { window: mockWindow }]]);
      getAllWebsiteWindows.mockReturnValue(mockWebsiteWindows);

      // Make sure BrowserWindow.fromWebContents returns our mock window
      (BrowserWindow.fromWebContents as jest.Mock).mockReturnValue(mockWindow);

      // Emit the event
      ipcMain.emit('website-editor-show-preview', mockEvent);

      // Wait for async import to complete
      await new Promise((resolve) => setTimeout(resolve, 50));

      expect(showWebsitePreview).toHaveBeenCalledWith('test-website');
    });

    it('should not call showWebsitePreview when window not found', async () => {
      const { showWebsitePreview } = require('../../app/ui/multi-window-manager');
      (BrowserWindow.fromWebContents as jest.Mock).mockReturnValue(null);

      ipcMain.emit('website-editor-show-preview', mockEvent);

      await new Promise((resolve) => setTimeout(resolve, 10));

      expect(showWebsitePreview).not.toHaveBeenCalled();
    });
  });

  describe('website-editor-show-edit', () => {
    it('should call hideWebsitePreview when window and website name are found', async () => {
      const { hideWebsitePreview, getAllWebsiteWindows } = require('../../app/ui/multi-window-manager');

      // Set up the mock so that the window appears in the website windows map
      const mockWebsiteWindows = new Map([['test-website', { window: mockWindow }]]);
      getAllWebsiteWindows.mockReturnValue(mockWebsiteWindows);

      // Make sure BrowserWindow.fromWebContents returns our mock window
      (BrowserWindow.fromWebContents as jest.Mock).mockReturnValue(mockWindow);

      ipcMain.emit('website-editor-show-edit', mockEvent);

      await new Promise((resolve) => setTimeout(resolve, 50));

      expect(hideWebsitePreview).toHaveBeenCalledWith('test-website');
    });

    it('should not call hideWebsitePreview when window not found', async () => {
      const { hideWebsitePreview } = require('../../app/ui/multi-window-manager');
      (BrowserWindow.fromWebContents as jest.Mock).mockReturnValue(null);

      ipcMain.emit('website-editor-show-edit', mockEvent);

      await new Promise((resolve) => setTimeout(resolve, 10));

      expect(hideWebsitePreview).not.toHaveBeenCalled();
    });
  });
});
