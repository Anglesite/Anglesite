/**
 * @file Tests for first launch setup flow
 */
import { handleFirstLaunch } from '../../app/utils/first-launch';
import { Store } from '../../app/store';

// Mock Electron modules
jest.mock('electron', () => ({
  app: {
    quit: jest.fn(),
  },
  dialog: {
    showMessageBoxSync: jest.fn(),
  },
}));

// Mock certificates module
jest.mock('../../app/certificates', () => ({
  isCAInstalledInSystem: jest.fn(),
  installCAInSystem: jest.fn(),
}));

// Mock window manager
jest.mock('../../app/ui/window-manager', () => ({
  showFirstLaunchAssistant: jest.fn(),
}));

// Mock store
const mockStore = {
  set: jest.fn(),
  get: jest.fn(),
};

describe('First Launch Setup', () => {
  beforeEach(() => {
    jest.clearAllMocks();
  });

  describe('handleFirstLaunch', () => {
    it('should default to HTTPS mode when CA is already installed', async () => {
      const { isCAInstalledInSystem } = require('../../app/certificates');
      const { showFirstLaunchAssistant } = require('../../app/ui/window-manager');

      isCAInstalledInSystem.mockReturnValue(true);

      await handleFirstLaunch(mockStore as unknown as Store);

      expect(isCAInstalledInSystem).toHaveBeenCalled();
      expect(mockStore.set).toHaveBeenCalledWith('httpsMode', 'https');
      expect(mockStore.set).toHaveBeenCalledWith('firstLaunchCompleted', true);
      expect(showFirstLaunchAssistant).not.toHaveBeenCalled();
    });

    it('should quit app when user cancels setup', async () => {
      const { isCAInstalledInSystem } = require('../../app/certificates');
      const { showFirstLaunchAssistant } = require('../../app/ui/window-manager');
      const { app } = require('electron');

      isCAInstalledInSystem.mockReturnValue(false);
      showFirstLaunchAssistant.mockResolvedValue(null);

      await handleFirstLaunch(mockStore as unknown as Store);

      expect(showFirstLaunchAssistant).toHaveBeenCalled();
      expect(app.quit).toHaveBeenCalled();
      expect(mockStore.set).not.toHaveBeenCalledWith('firstLaunchCompleted', true);
    });

    it('should install CA and set HTTPS mode when user chooses HTTPS', async () => {
      const { isCAInstalledInSystem, installCAInSystem } = require('../../app/certificates');
      const { showFirstLaunchAssistant } = require('../../app/ui/window-manager');
      const { dialog } = require('electron');

      isCAInstalledInSystem.mockReturnValue(false);
      showFirstLaunchAssistant.mockResolvedValue('https');
      installCAInSystem.mockResolvedValue(true);

      await handleFirstLaunch(mockStore as unknown as Store);

      expect(showFirstLaunchAssistant).toHaveBeenCalled();
      expect(installCAInSystem).toHaveBeenCalled();
      expect(mockStore.set).toHaveBeenCalledWith('httpsMode', 'https');
      expect(mockStore.set).toHaveBeenCalledWith('firstLaunchCompleted', true);
      expect(dialog.showMessageBoxSync).not.toHaveBeenCalled();
    });

    it('should fall back to HTTP when CA installation fails', async () => {
      const { isCAInstalledInSystem, installCAInSystem } = require('../../app/certificates');
      const { showFirstLaunchAssistant } = require('../../app/ui/window-manager');
      const { dialog } = require('electron');

      isCAInstalledInSystem.mockReturnValue(false);
      showFirstLaunchAssistant.mockResolvedValue('https');
      installCAInSystem.mockResolvedValue(false);

      await handleFirstLaunch(mockStore as unknown as Store);

      expect(installCAInSystem).toHaveBeenCalled();
      expect(mockStore.set).toHaveBeenCalledWith('httpsMode', 'http');
      expect(mockStore.set).toHaveBeenCalledWith('firstLaunchCompleted', true);
      expect(dialog.showMessageBoxSync).toHaveBeenCalledWith({
        type: 'warning',
        title: 'Certificate Installation Failed',
        message: 'Failed to install the security certificate.',
        detail: 'Anglesite will continue in HTTP mode. You can retry HTTPS setup in the settings.',
        buttons: ['Continue'],
      });
    });

    it('should handle CA installation errors gracefully', async () => {
      const { isCAInstalledInSystem, installCAInSystem } = require('../../app/certificates');
      const { showFirstLaunchAssistant } = require('../../app/ui/window-manager');
      const { dialog } = require('electron');

      isCAInstalledInSystem.mockReturnValue(false);
      showFirstLaunchAssistant.mockResolvedValue('https');
      installCAInSystem.mockRejectedValue(new Error('Installation error'));

      await handleFirstLaunch(mockStore as unknown as Store);

      expect(installCAInSystem).toHaveBeenCalled();
      expect(mockStore.set).toHaveBeenCalledWith('httpsMode', 'http');
      expect(mockStore.set).toHaveBeenCalledWith('firstLaunchCompleted', true);
      expect(dialog.showMessageBoxSync).toHaveBeenCalledWith({
        type: 'error',
        title: 'Setup Error',
        message: 'An error occurred during setup.',
        detail: 'Anglesite will continue in HTTP mode.',
        buttons: ['Continue'],
      });
    });

    it('should set HTTP mode when user chooses HTTP', async () => {
      const { isCAInstalledInSystem, installCAInSystem } = require('../../app/certificates');
      const { showFirstLaunchAssistant } = require('../../app/ui/window-manager');
      const { dialog } = require('electron');

      isCAInstalledInSystem.mockReturnValue(false);
      showFirstLaunchAssistant.mockResolvedValue('http');

      await handleFirstLaunch(mockStore as unknown as Store);

      expect(showFirstLaunchAssistant).toHaveBeenCalled();
      expect(installCAInSystem).not.toHaveBeenCalled();
      expect(mockStore.set).toHaveBeenCalledWith('httpsMode', 'http');
      expect(mockStore.set).toHaveBeenCalledWith('firstLaunchCompleted', true);
      expect(dialog.showMessageBoxSync).not.toHaveBeenCalled();
    });

    it('should handle unexpected user choice values', async () => {
      const { isCAInstalledInSystem, installCAInSystem } = require('../../app/certificates');
      const { showFirstLaunchAssistant } = require('../../app/ui/window-manager');

      isCAInstalledInSystem.mockReturnValue(false);
      showFirstLaunchAssistant.mockResolvedValue('unknown' as any);

      await handleFirstLaunch(mockStore as unknown as Store);

      expect(showFirstLaunchAssistant).toHaveBeenCalled();
      expect(installCAInSystem).not.toHaveBeenCalled();
      expect(mockStore.set).toHaveBeenCalledWith('httpsMode', 'http');
      expect(mockStore.set).toHaveBeenCalledWith('firstLaunchCompleted', true);
    });
  });
});
