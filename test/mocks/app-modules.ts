// test/mocks/app-modules.ts

// Mock UI modules
const mockWindowManager = {
  showPreview: jest.fn(),
  hidePreview: jest.fn(),
  reloadPreview: jest.fn(),
  togglePreviewDevTools: jest.fn(),
  getNativeInput: jest.fn(),
  getBagItMetadata: jest.fn(),
};

jest.mock('../../app/ui/window-manager', () => mockWindowManager);

const mockMultiWindowManager = {
  createHelpWindow: jest.fn(() => ({})), // Return mock object
  closeAllWindows: jest.fn(),
  restoreWindowStates: jest.fn(),
  getAllWebsiteWindows: jest.fn(() => new Map()),
  createWebsiteWindow: jest.fn(() => ({})), // Return mock object
  loadWebsiteContent: jest.fn(),
  getHelpWindow: jest.fn(),
  getWebsiteWindow: jest.fn(),
  saveWindowStates: jest.fn(),
};

jest.mock('../../app/ui/multi-window-manager', () => mockMultiWindowManager);

const mockAppMenu = {
  createApplicationMenu: jest.fn(),
  updateApplicationMenu: jest.fn(),
};

jest.mock('../../app/ui/menu', () => mockAppMenu);

const mockIpcHandlers = {
  setupIpcMainListeners: jest.fn(),
};

jest.mock('../../app/ipc/handlers', () => mockIpcHandlers);

const mockStoreInstance = {
  get: jest.fn(),
  set: jest.fn(),
  saveWindowStates: jest.fn(),
  getWindowStates: jest.fn(() => [] as unknown[]), // Default for multi-window-manager
  clearWindowStates: jest.fn(),
  getAll: jest.fn(() => ({})),
  setAll: jest.fn(),
};

jest.mock('../../app/store', () => ({
  Store: jest.fn().mockImplementation(() => mockStoreInstance),
}));

const mockFirstLaunch = {
  handleFirstLaunch: jest.fn(),
};

jest.mock('../../app/utils/first-launch', () => mockFirstLaunch);

const mockEleventy = {
  cleanupEleventyServer: jest.fn(),
  startDefaultEleventyServer: jest.fn(),
  getCurrentLiveServerUrl: jest.fn(() => 'https://anglesite.test:8080'), // Default for multi-window-manager
  isLiveServerReady: jest.fn(() => true),
  switchToWebsite: jest.fn(),
  setLiveServerUrl: jest.fn(),
  setCurrentWebsiteName: jest.fn(),
};

jest.mock('../../app/server/eleventy', () => mockEleventy);

const mockHttpsProxy = {
  createHttpsProxy: jest.fn(),
  restartHttpsProxy: jest.fn(),
};

jest.mock('../../app/server/https-proxy', () => mockHttpsProxy);

const mockHostsManager = {
  addLocalDnsResolution: jest.fn(),
  cleanupHostsFile: jest.fn(),
  checkAndSuggestTouchIdSetup: jest.fn(),
};

jest.mock('../../app/dns/hosts-manager', () => mockHostsManager);

const mockThemeManager = {
  initialize: jest.fn(),
  applyThemeToWindow: jest.fn(),
};

jest.mock('../../app/ui/theme-manager', () => ({ themeManager: mockThemeManager }));

const mockWebsiteManager = {
  createWebsiteWithName: jest.fn(),
  validateWebsiteName: jest.fn(),
  listWebsites: jest.fn(() => ['test-site', 'my-website']),
  getWebsitePath: jest.fn(),
  renameWebsite: jest.fn(),
  deleteWebsite: jest.fn(),
};

jest.mock('../../app/utils/website-manager', () => mockWebsiteManager);

const mockTemplateLoader = {
  loadTemplateAsDataUrl: jest.fn((templateName: string) => {
    return `data:text/html;charset=utf-8,<h1>Mock ${templateName}</h1>`;
  }),
};

jest.mock('../../app/ui/template-loader', () => mockTemplateLoader);

// Path is already mocked by node-modules.ts

export const resetAppModulesMocks = () => {
  mockWindowManager.showPreview.mockClear();
  mockWindowManager.hidePreview.mockClear();
  mockWindowManager.reloadPreview.mockClear();
  mockWindowManager.togglePreviewDevTools.mockClear();
  mockWindowManager.getNativeInput.mockClear();
  mockWindowManager.getBagItMetadata.mockClear();

  mockMultiWindowManager.createHelpWindow.mockClear();
  mockMultiWindowManager.closeAllWindows.mockClear();
  mockMultiWindowManager.restoreWindowStates.mockClear();
  mockMultiWindowManager.getAllWebsiteWindows.mockClear();
  mockMultiWindowManager.createWebsiteWindow.mockClear();
  mockMultiWindowManager.loadWebsiteContent.mockClear();
  mockMultiWindowManager.getHelpWindow.mockClear();
  mockMultiWindowManager.getWebsiteWindow.mockClear();
  mockMultiWindowManager.saveWindowStates.mockClear();

  mockAppMenu.createApplicationMenu.mockClear();
  mockAppMenu.updateApplicationMenu.mockClear();

  mockIpcHandlers.setupIpcMainListeners.mockClear();

  // Store mock instance needs special handling to preserve implementation
  const getImpl = mockStoreInstance.get.getMockImplementation();
  const setImpl = mockStoreInstance.set.getMockImplementation();
  const saveWindowStatesImpl = mockStoreInstance.saveWindowStates.getMockImplementation();
  const getWindowStatesImpl = mockStoreInstance.getWindowStates.getMockImplementation();
  const clearWindowStatesImpl = mockStoreInstance.clearWindowStates.getMockImplementation();
  const getAllImpl = mockStoreInstance.getAll.getMockImplementation();
  const setAllImpl = mockStoreInstance.setAll.getMockImplementation();

  mockStoreInstance.get.mockClear();
  mockStoreInstance.set.mockClear();
  mockStoreInstance.saveWindowStates.mockClear();
  mockStoreInstance.getWindowStates.mockClear();
  mockStoreInstance.clearWindowStates.mockClear();
  mockStoreInstance.getAll.mockClear();
  mockStoreInstance.setAll.mockClear();

  if (getImpl) mockStoreInstance.get.mockImplementation(getImpl);
  if (setImpl) mockStoreInstance.set.mockImplementation(setImpl);
  if (saveWindowStatesImpl) mockStoreInstance.saveWindowStates.mockImplementation(saveWindowStatesImpl);
  if (getWindowStatesImpl) mockStoreInstance.getWindowStates.mockImplementation(getWindowStatesImpl);
  if (clearWindowStatesImpl) mockStoreInstance.clearWindowStates.mockImplementation(clearWindowStatesImpl);
  if (getAllImpl) mockStoreInstance.getAll.mockImplementation(getAllImpl);
  if (setAllImpl) mockStoreInstance.setAll.mockImplementation(setAllImpl);

  mockFirstLaunch.handleFirstLaunch.mockClear();

  mockEleventy.cleanupEleventyServer.mockClear();
  mockEleventy.startDefaultEleventyServer.mockClear();
  mockEleventy.getCurrentLiveServerUrl.mockClear();
  mockEleventy.isLiveServerReady.mockClear();
  mockEleventy.switchToWebsite.mockClear();
  mockEleventy.setLiveServerUrl.mockClear();
  mockEleventy.setCurrentWebsiteName.mockClear();

  mockHttpsProxy.createHttpsProxy.mockClear();
  mockHttpsProxy.restartHttpsProxy.mockClear();

  mockHostsManager.addLocalDnsResolution.mockClear();
  mockHostsManager.cleanupHostsFile.mockClear();
  mockHostsManager.checkAndSuggestTouchIdSetup.mockClear();

  mockThemeManager.initialize.mockClear();
  mockThemeManager.applyThemeToWindow.mockClear();

  mockWebsiteManager.createWebsiteWithName.mockClear();
  mockWebsiteManager.validateWebsiteName.mockClear();
  mockWebsiteManager.listWebsites.mockClear();
  mockWebsiteManager.getWebsitePath.mockClear();
  mockWebsiteManager.renameWebsite.mockClear();
  mockWebsiteManager.deleteWebsite.mockClear();

  mockTemplateLoader.loadTemplateAsDataUrl.mockClear();
};

export {
  mockWindowManager,
  mockMultiWindowManager,
  mockAppMenu,
  mockIpcHandlers,
  mockStoreInstance,
  mockFirstLaunch,
  mockEleventy,
  mockHttpsProxy,
  mockHostsManager,
  mockThemeManager,
  mockWebsiteManager,
  mockTemplateLoader,
};
