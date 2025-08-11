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
  let createApplicationMenu: () => any;

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
    mockBrowserWindow.getFocusedWindow.mockReturnValue(null);
    mockGetAllWebsiteWindows.mockReturnValue(new Map());
    mockGetHelpWindow.mockReturnValue(null);
  });

  it('should successfully create a new website when user provides valid input', async () => {
    // Create the menu to get the New Website click handler
    createApplicationMenu();

    const template = mockMenu.buildFromTemplate.mock.calls[0][0];
    const fileMenu = template.find((item: any) => item.label === 'File');
    const newWebsiteItem = fileMenu?.submenu?.find((item: any) => item.label === 'New Website...');

    expect(newWebsiteItem).toBeDefined();
    expect(typeof newWebsiteItem.click).toBe('function');

    // Execute the New Website click handler
    await newWebsiteItem.click();

    // Verify the complete workflow
    expect(mockGetNativeInput).toHaveBeenCalledWith('New Website', 'Enter a name for your new website:');
    expect(mockCreateWebsiteWithName).toHaveBeenCalledWith('My Test Site');
    expect(mockCreateWebsiteWindow).toHaveBeenCalledWith('My Test Site', '/path/to/website');
    expect(mockSwitchToWebsite).toHaveBeenCalledWith('/path/to/website');
    expect(mockAddLocalDnsResolution).toHaveBeenCalledWith('My Test Site.test');
    expect(mockRestartHttpsProxy).toHaveBeenCalledWith(8080, 8081, 'My Test Site.test');
    expect(mockLoadWebsiteContent).toHaveBeenCalledWith('My Test Site');
  });

  it('should handle user cancellation gracefully', async () => {
    mockGetNativeInput.mockResolvedValue(null); // User cancelled
    const consoleSpy = jest.spyOn(console, 'log').mockImplementation();

    createApplicationMenu();
    const template = mockMenu.buildFromTemplate.mock.calls[0][0];
    const fileMenu = template.find((item: any) => item.label === 'File');
    const newWebsiteItem = fileMenu?.submenu?.find((item: any) => item.label === 'New Website...');

    await newWebsiteItem.click();

    expect(mockGetNativeInput).toHaveBeenCalled();
    expect(mockCreateWebsiteWithName).not.toHaveBeenCalled();
    expect(consoleSpy).toHaveBeenCalledWith('DEBUG: User cancelled website creation');

    consoleSpy.mockRestore();
  });

  it('should handle empty website name gracefully', async () => {
    mockGetNativeInput.mockResolvedValue('   '); // Empty/whitespace name
    const consoleSpy = jest.spyOn(console, 'log').mockImplementation();

    createApplicationMenu();
    const template = mockMenu.buildFromTemplate.mock.calls[0][0];
    const fileMenu = template.find((item: any) => item.label === 'File');
    const newWebsiteItem = fileMenu?.submenu?.find((item: any) => item.label === 'New Website...');

    await newWebsiteItem.click();

    expect(mockGetNativeInput).toHaveBeenCalled();
    expect(mockCreateWebsiteWithName).not.toHaveBeenCalled();
    expect(consoleSpy).toHaveBeenCalledWith('DEBUG: User cancelled website creation');

    consoleSpy.mockRestore();
  });

  it('should handle HTTP-only mode', async () => {
    mockStoreGet.mockReturnValue('http'); // HTTP mode instead of HTTPS
    const consoleSpy = jest.spyOn(console, 'log').mockImplementation();

    createApplicationMenu();
    const template = mockMenu.buildFromTemplate.mock.calls[0][0];
    const fileMenu = template.find((item: any) => item.label === 'File');
    const newWebsiteItem = fileMenu?.submenu?.find((item: any) => item.label === 'New Website...');

    await newWebsiteItem.click();

    expect(mockGetNativeInput).toHaveBeenCalled();
    expect(mockCreateWebsiteWithName).toHaveBeenCalled();
    expect(mockRestartHttpsProxy).not.toHaveBeenCalled();
    expect(consoleSpy).toHaveBeenCalledWith('DEBUG: HTTP-only mode by user preference, skipping HTTPS proxy');

    consoleSpy.mockRestore();
  });

  it('should handle HTTPS proxy failure gracefully', async () => {
    mockRestartHttpsProxy.mockResolvedValue(false); // Proxy fails
    const consoleSpy = jest.spyOn(console, 'log').mockImplementation();

    createApplicationMenu();
    const template = mockMenu.buildFromTemplate.mock.calls[0][0];
    const fileMenu = template.find((item: any) => item.label === 'File');
    const newWebsiteItem = fileMenu?.submenu?.find((item: any) => item.label === 'New Website...');

    await newWebsiteItem.click();

    expect(mockRestartHttpsProxy).toHaveBeenCalled();
    expect(consoleSpy).toHaveBeenCalledWith('DEBUG: HTTPS proxy failed, using HTTP mode');
    expect(mockLoadWebsiteContent).toHaveBeenCalled(); // Should still continue

    consoleSpy.mockRestore();
  });

  it('should handle errors during website creation', async () => {
    const testError = new Error('Website creation failed');
    mockCreateWebsiteWithName.mockRejectedValue(testError);
    const consoleSpy = jest.spyOn(console, 'error').mockImplementation();

    createApplicationMenu();
    const template = mockMenu.buildFromTemplate.mock.calls[0][0];
    const fileMenu = template.find((item: any) => item.label === 'File');
    const newWebsiteItem = fileMenu?.submenu?.find((item: any) => item.label === 'New Website...');

    await newWebsiteItem.click();

    expect(mockGetNativeInput).toHaveBeenCalled();
    expect(mockCreateWebsiteWithName).toHaveBeenCalled();
    expect(consoleSpy).toHaveBeenCalledWith('DEBUG: Error creating/opening website:', testError);

    consoleSpy.mockRestore();
  });

  it('should trim whitespace from website names', async () => {
    mockGetNativeInput.mockResolvedValue('  My Site  '); // Name with whitespace

    createApplicationMenu();
    const template = mockMenu.buildFromTemplate.mock.calls[0][0];
    const fileMenu = template.find((item: any) => item.label === 'File');
    const newWebsiteItem = fileMenu?.submenu?.find((item: any) => item.label === 'New Website...');

    await newWebsiteItem.click();

    expect(mockCreateWebsiteWithName).toHaveBeenCalledWith('My Site');
    expect(mockCreateWebsiteWindow).toHaveBeenCalledWith('My Site', '/path/to/website');
    expect(mockAddLocalDnsResolution).toHaveBeenCalledWith('My Site.test');
    expect(mockLoadWebsiteContent).toHaveBeenCalledWith('My Site');
  });

  it('should have correct menu structure', () => {
    createApplicationMenu();
    const template = mockMenu.buildFromTemplate.mock.calls[0][0];
    const fileMenu = template.find((item: any) => item.label === 'File');
    const newWebsiteItem = fileMenu?.submenu?.find((item: any) => item.label === 'New Website...');

    expect(newWebsiteItem).toBeDefined();
    expect(newWebsiteItem.label).toBe('New Website...');
    expect(newWebsiteItem.accelerator).toBe('CmdOrCtrl+N');
    expect(typeof newWebsiteItem.click).toBe('function');
  });
});
