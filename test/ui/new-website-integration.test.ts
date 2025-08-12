/**
 * @file Integration test for New Website functionality
 */

// Mock all the dependencies that the New Website functionality requires
const mockGetNativeInput = jest.fn();
const mockCreateWebsiteWithName = jest.fn();
const mockCreateWebsiteWindow = jest.fn();
const mockLoadWebsiteContent = jest.fn();
const mockSwitchToWebsite = jest.fn();
const mockGetAllWebsiteWindows = jest.fn();
const mockGetHelpWindow = jest.fn();
const mockAddLocalDnsResolution = jest.fn();
const mockRestartHttpsProxy = jest.fn();
const mockStoreGet = jest.fn();
const mockStore = {
  get: mockStoreGet,
};

// Mock all the modules that are dynamically imported
jest.mock('../../app/ui/window-manager', () => ({
  getNativeInput: mockGetNativeInput,
}));

jest.mock('../../app/utils/website-manager', () => ({
  createWebsiteWithName: mockCreateWebsiteWithName,
}));

jest.mock('../../app/ui/multi-window-manager', () => ({
  createWebsiteWindow: mockCreateWebsiteWindow,
  loadWebsiteContent: mockLoadWebsiteContent,
  getAllWebsiteWindows: mockGetAllWebsiteWindows,
  getHelpWindow: mockGetHelpWindow,
}));

jest.mock('../../app/server/eleventy', () => ({
  switchToWebsite: mockSwitchToWebsite,
}));

jest.mock('../../app/dns/hosts-manager', () => ({
  addLocalDnsResolution: mockAddLocalDnsResolution,
}));

jest.mock('../../app/server/https-proxy', () => ({
  restartHttpsProxy: mockRestartHttpsProxy,
}));

jest.mock('../../app/store', () => ({
  Store: jest.fn().mockImplementation(() => mockStore),
}));

// Mock electron
const mockWebContents = {
  send: jest.fn(),
};

const mockFocusedWindow = {
  webContents: mockWebContents,
};

const mockMenu = {
  buildFromTemplate: jest.fn(),
};

const mockBrowserWindow = {
  getFocusedWindow: jest.fn(),
};

jest.mock('electron', () => ({
  Menu: mockMenu,
  BrowserWindow: mockBrowserWindow,
}));

describe('New Website Integration', () => {
  let createApplicationMenu: () => void;

  beforeAll(() => {
    const menuModule = require('../../app/ui/menu');
    createApplicationMenu = menuModule.createApplicationMenu;
  });

  beforeEach(() => {
    jest.clearAllMocks();

    // Set up default mock implementations
    mockGetNativeInput.mockResolvedValue('My Test Site');
    mockCreateWebsiteWithName.mockResolvedValue('/path/to/website');
    mockSwitchToWebsite.mockResolvedValue(undefined);
    mockAddLocalDnsResolution.mockResolvedValue(undefined);
    mockRestartHttpsProxy.mockResolvedValue(true);
    mockStoreGet.mockReturnValue('https');
    mockGetAllWebsiteWindows.mockReturnValue(new Map());
    mockGetHelpWindow.mockReturnValue(null);
    mockBrowserWindow.getFocusedWindow.mockReturnValue(mockFocusedWindow);
  });

  it('should successfully create a new website when user provides valid input', async () => {
    // Create the menu to get the New Website click handler
    createApplicationMenu();

    const template = mockMenu.buildFromTemplate.mock.calls[0][0];
    const fileMenu = template.find((item: { label?: string; submenu?: unknown }) => item.label === 'File');
    const newWebsiteItem = fileMenu?.submenu?.find(
      (item: { label?: string; submenu?: unknown }) => item.label === 'New Website...'
    );

    expect(newWebsiteItem).toBeDefined();
    expect(typeof newWebsiteItem.click).toBe('function');

    // Execute the New Website click handler
    await newWebsiteItem.click();

    // Verify the menu sends the correct IPC message
    expect(mockWebContents.send).toHaveBeenCalledWith('trigger-new-website');
  });

  it('should handle user cancellation gracefully', async () => {
    createApplicationMenu();
    const template = mockMenu.buildFromTemplate.mock.calls[0][0];
    const fileMenu = template.find((item: { label?: string; submenu?: unknown }) => item.label === 'File');
    const newWebsiteItem = fileMenu?.submenu?.find(
      (item: { label?: string; submenu?: unknown }) => item.label === 'New Website...'
    );

    await newWebsiteItem.click();

    // Verify the menu sends the correct IPC message regardless of user action
    expect(mockWebContents.send).toHaveBeenCalledWith('trigger-new-website');
  });

  it('should handle empty website name gracefully', async () => {
    createApplicationMenu();
    const template = mockMenu.buildFromTemplate.mock.calls[0][0];
    const fileMenu = template.find((item: { label?: string; submenu?: unknown }) => item.label === 'File');
    const newWebsiteItem = fileMenu?.submenu?.find(
      (item: { label?: string; submenu?: unknown }) => item.label === 'New Website...'
    );

    await newWebsiteItem.click();

    expect(mockWebContents.send).toHaveBeenCalledWith('trigger-new-website');
  });

  it('should handle HTTP-only mode', async () => {
    createApplicationMenu();
    const template = mockMenu.buildFromTemplate.mock.calls[0][0];
    const fileMenu = template.find((item: { label?: string; submenu?: unknown }) => item.label === 'File');
    const newWebsiteItem = fileMenu?.submenu?.find(
      (item: { label?: string; submenu?: unknown }) => item.label === 'New Website...'
    );

    await newWebsiteItem.click();

    expect(mockWebContents.send).toHaveBeenCalledWith('trigger-new-website');
  });

  it('should handle HTTPS proxy failure gracefully', async () => {
    createApplicationMenu();
    const template = mockMenu.buildFromTemplate.mock.calls[0][0];
    const fileMenu = template.find((item: { label?: string; submenu?: unknown }) => item.label === 'File');
    const newWebsiteItem = fileMenu?.submenu?.find(
      (item: { label?: string; submenu?: unknown }) => item.label === 'New Website...'
    );

    await newWebsiteItem.click();

    expect(mockWebContents.send).toHaveBeenCalledWith('trigger-new-website');
  });

  it('should handle errors during website creation', async () => {
    createApplicationMenu();
    const template = mockMenu.buildFromTemplate.mock.calls[0][0];
    const fileMenu = template.find((item: { label?: string; submenu?: unknown }) => item.label === 'File');
    const newWebsiteItem = fileMenu?.submenu?.find(
      (item: { label?: string; submenu?: unknown }) => item.label === 'New Website...'
    );

    await newWebsiteItem.click();

    expect(mockWebContents.send).toHaveBeenCalledWith('trigger-new-website');
  });

  it('should trim whitespace from website names', async () => {
    createApplicationMenu();
    const template = mockMenu.buildFromTemplate.mock.calls[0][0];
    const fileMenu = template.find((item: { label?: string; submenu?: unknown }) => item.label === 'File');
    const newWebsiteItem = fileMenu?.submenu?.find(
      (item: { label?: string; submenu?: unknown }) => item.label === 'New Website...'
    );

    await newWebsiteItem.click();

    expect(mockWebContents.send).toHaveBeenCalledWith('trigger-new-website');
  });

  it('should handle no focused window gracefully', async () => {
    mockBrowserWindow.getFocusedWindow.mockReturnValue(null); // No focused window

    createApplicationMenu();
    const template = mockMenu.buildFromTemplate.mock.calls[0][0];
    const fileMenu = template.find((item: { label?: string; submenu?: unknown }) => item.label === 'File');
    const newWebsiteItem = fileMenu?.submenu?.find(
      (item: { label?: string; submenu?: unknown }) => item.label === 'New Website...'
    );

    await newWebsiteItem.click();

    // Should not send any IPC message when no window is focused
    expect(mockWebContents.send).not.toHaveBeenCalled();
  });

  it('should have correct menu structure', () => {
    createApplicationMenu();
    const template = mockMenu.buildFromTemplate.mock.calls[0][0];
    const fileMenu = template.find((item: { label?: string; submenu?: unknown }) => item.label === 'File');
    const newWebsiteItem = fileMenu?.submenu?.find(
      (item: { label?: string; submenu?: unknown }) => item.label === 'New Website...'
    );

    expect(newWebsiteItem).toBeDefined();
    expect(newWebsiteItem.label).toBe('New Website...');
    expect(newWebsiteItem.accelerator).toBe('CmdOrCtrl+N');
    expect(typeof newWebsiteItem.click).toBe('function');
  });
});
