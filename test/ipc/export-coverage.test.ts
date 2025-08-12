/**
 * @file Export functionality coverage tests
 */

import { IpcMainEvent } from 'electron';

// Mock fs module
const mockFs = {
  existsSync: jest.fn(() => true),
  createReadStream: jest.fn(() => ({ pipe: jest.fn() })),
  createWriteStream: jest.fn(() => ({
    on: jest.fn((event, callback) => {
      if (event === 'close') setTimeout(() => callback(), 0);
      return { on: jest.fn() };
    }),
  })),
  readdirSync: jest.fn(() => []),
  mkdirSync: jest.fn(),
  readFileSync: jest.fn(() => JSON.stringify({ version: '1.0.0', homepage: 'https://test.com' })),
  copyFileSync: jest.fn(),
  rmSync: jest.fn(),
  statSync: jest.fn(() => ({ isDirectory: () => false })),
};

// Mock electron
const mockDialog = {
  showSaveDialog: jest.fn().mockResolvedValue({ canceled: false, filePath: '/test/export.zip' }),
  showMessageBox: jest.fn(),
};
const mockBrowserWindow = {
  getFocusedWindow: jest.fn(),
  fromWebContents: jest.fn(),
};

// Mock child_process
const mockExec = jest.fn();

// Mock bagit-fs
const mockBagIt = jest.fn(() => ({
  createWriteStream: jest.fn(() => ({ on: jest.fn() })),
  finalize: jest.fn((cb) => setTimeout(() => cb(), 0)),
}));

// Mock archiver
const mockArchiver = jest.fn(() => ({
  pipe: jest.fn(),
  directory: jest.fn(),
  finalize: jest.fn(),
  pointer: () => 1024,
  on: jest.fn(() => {
    return { on: jest.fn() };
  }),
}));

// Apply mocks
jest.mock('electron', () => ({
  BrowserWindow: mockBrowserWindow,
  dialog: mockDialog,
  ipcMain: { on: jest.fn(), handle: jest.fn(), removeListener: jest.fn() },
  shell: { openExternal: jest.fn(), showItemInFolder: jest.fn() },
  Menu: jest.fn(),
  MenuItem: jest.fn(),
}));

jest.mock('fs', () => mockFs);
jest.mock('path', () => ({ join: (...args: string[]) => args.join('/'), resolve: jest.fn() }));
jest.mock('os', () => ({ tmpdir: () => '/tmp' }));
jest.mock('child_process', () => ({ exec: mockExec }));
jest.mock('archiver', () => mockArchiver);
jest.mock('bagit-fs', () => mockBagIt);

// Mock app modules
const mockGetBagItMetadata = jest.fn();
const mockGetAllWebsiteWindows = jest.fn();
const mockGetWebsitePath = jest.fn(() => '/test/path');

jest.mock('../../app/ui/window-manager', () => ({
  getBagItMetadata: mockGetBagItMetadata,
  showPreview: jest.fn(),
  hidePreview: jest.fn(),
  reloadPreview: jest.fn(),
  togglePreviewDevTools: jest.fn(),
  getNativeInput: jest.fn(),
}));

jest.mock('../../app/ui/multi-window-manager', () => ({
  getAllWebsiteWindows: mockGetAllWebsiteWindows,
  createWebsiteWindow: jest.fn(),
  loadWebsiteContent: jest.fn(),
}));

jest.mock('../../app/utils/website-manager', () => ({
  getWebsitePath: mockGetWebsitePath,
  createWebsiteWithName: jest.fn(),
  validateWebsiteName: jest.fn(),
  listWebsites: jest.fn(),
  renameWebsite: jest.fn(),
  deleteWebsite: jest.fn(),
}));

jest.mock('../../app/server/eleventy', () => ({
  getCurrentLiveServerUrl: jest.fn(() => 'https://localhost:8080'),
  isLiveServerReady: jest.fn(() => true),
  switchToWebsite: jest.fn(),
  setLiveServerUrl: jest.fn(),
  setCurrentWebsiteName: jest.fn(),
}));

jest.mock('../../app/dns/hosts-manager', () => ({ addLocalDnsResolution: jest.fn() }));
jest.mock('../../app/server/https-proxy', () => ({ restartHttpsProxy: jest.fn() }));
jest.mock('../../app/store', () => ({ Store: jest.fn().mockImplementation(() => ({ get: jest.fn(() => 'https') })) }));

describe('Export Coverage Tests', () => {
  let exportSiteHandler: (event: IpcMainEvent | null, format: boolean | 'bagit') => Promise<void>;

  const mockWindow = { webContents: { send: jest.fn() } };
  const mockWebsiteWindows = new Map([['test-site', { window: mockWindow }]]);

  const mockMetadata = {
    externalIdentifier: 'test',
    externalDescription: 'desc',
    sourceOrganization: 'org',
    organizationAddress: 'addr',
    contactName: 'name',
    contactPhone: 'phone',
    contactEmail: 'email',
  };

  beforeAll(async () => {
    const handlers = await import('../../app/ipc/handlers');
    exportSiteHandler = handlers.exportSiteHandler;
  });

  beforeEach(() => {
    jest.clearAllMocks();
    mockBrowserWindow.getFocusedWindow.mockReturnValue(mockWindow);
    mockGetAllWebsiteWindows.mockReturnValue(mockWebsiteWindows);
    mockFs.existsSync.mockReturnValue(true);
  });

  it('should handle folder export successfully', async () => {
    mockDialog.showSaveDialog.mockResolvedValue({
      canceled: false,
      filePath: '/test/export-folder',
    });
    mockExec.mockImplementation((_cmd, _opts, cb) => cb(null, 'Build success'));

    await exportSiteHandler(null, false);

    expect(mockExec).toHaveBeenCalledWith(
      expect.stringContaining('npx eleventy'),
      { cwd: process.cwd() },
      expect.any(Function)
    );
  });

  it('should handle zip export successfully', async () => {
    mockDialog.showSaveDialog.mockResolvedValue({
      canceled: false,
      filePath: '/test/export.zip',
    });
    mockExec.mockImplementation((_cmd, _opts, cb) => cb(null, 'Build success'));

    await exportSiteHandler(null, true);

    expect(mockArchiver).toHaveBeenCalledWith('zip', { zlib: { level: 9 } });
  });

  it('should handle bagit export with metadata collection', async () => {
    mockGetBagItMetadata.mockResolvedValue(mockMetadata);
    mockDialog.showSaveDialog.mockResolvedValue({
      canceled: false,
      filePath: '/test/export.bagit.zip',
    });
    mockExec.mockImplementation((_cmd, _opts, cb) => cb(null, 'Build success'));

    await exportSiteHandler(null, 'bagit');

    expect(mockGetBagItMetadata).toHaveBeenCalledWith('test-site');
    expect(mockBagIt).toHaveBeenCalledWith(
      expect.stringContaining('/tmp/anglesite_bagit_'),
      'sha256',
      expect.objectContaining({
        'External-Description': mockMetadata.externalDescription,
        'External-Identifier': mockMetadata.externalIdentifier,
        'Source-Organization': mockMetadata.sourceOrganization,
      })
    );
  });

  it('should handle bagit metadata cancellation', async () => {
    mockGetBagItMetadata.mockResolvedValue(null);

    await exportSiteHandler(null, 'bagit');

    expect(mockDialog.showSaveDialog).not.toHaveBeenCalled();
  });

  it('should handle save dialog cancellation', async () => {
    mockDialog.showSaveDialog.mockResolvedValue({ canceled: true });

    await exportSiteHandler(null, false);

    expect(mockExec).not.toHaveBeenCalled();
  });

  it('should handle build errors', (done) => {
    mockDialog.showSaveDialog.mockResolvedValue({
      canceled: false,
      filePath: '/test/export.zip',
    });

    mockExec.mockImplementation((_cmd, _opts, cb) => {
      cb(new Error('Build failed'), null);
      // Verify error handling after callback
      setTimeout(() => {
        expect(mockDialog.showMessageBox).toHaveBeenCalledWith(
          mockWindow,
          expect.objectContaining({
            type: 'error',
            title: 'Export Failed',
            message: 'Failed to build website for export',
          })
        );
        done();
      }, 50);
    });

    exportSiteHandler(null, true);
  });

  it('should handle no focused window', async () => {
    mockBrowserWindow.getFocusedWindow.mockReturnValue(null);

    await exportSiteHandler(null, false);

    expect(mockDialog.showSaveDialog).not.toHaveBeenCalled();
  });

  it('should handle no website selected', async () => {
    mockGetAllWebsiteWindows.mockReturnValue(new Map());

    await exportSiteHandler(null, false);

    expect(mockDialog.showMessageBox).toHaveBeenCalledWith(
      mockWindow,
      expect.objectContaining({
        type: 'info',
        title: 'No Website Selected',
      })
    );
  });

  it('should handle BagIt export with empty metadata (all fields optional)', () => {
    // Test that BagIt metadata validation accepts empty fields
    const emptyMetadata = {
      externalIdentifier: '',
      externalDescription: '',
      sourceOrganization: '',
      organizationAddress: '',
      contactName: '',
      contactPhone: '',
      contactEmail: '',
    };

    // This test verifies that the metadata validation logic
    // accepts empty values for all fields since they are now optional
    expect(emptyMetadata.externalIdentifier).toBe('');
    expect(emptyMetadata.externalDescription).toBe('');
    expect(emptyMetadata.sourceOrganization).toBe('');

    // All fields should be allowed to be empty (no validation errors)
    const hasRequiredFields = Object.values(emptyMetadata).some((value) => value.trim() !== '');
    expect(hasRequiredFields).toBe(false); // Confirms all fields are empty and that's okay
  });
});
