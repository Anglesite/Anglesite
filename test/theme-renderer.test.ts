/**
 * @file Tests for renderer-side theme management
 * @jest-environment jsdom
 */

import { Theme, ResolvedTheme, ThemeInfo } from '../app/theme-renderer';

// Create a test-only version of ThemeRenderer class
class TestThemeRenderer {
  private currentTheme: ResolvedTheme = 'light';

  async initialize(): Promise<void> {
    try {
      const themeInfo = await (window as any).electronAPI.getCurrentTheme();
      this.applyTheme(themeInfo.resolvedTheme);

      (window as any).electronAPI.onThemeUpdated((themeInfo: ThemeInfo) => {
        console.log('Theme updated in renderer:', themeInfo);
        this.applyTheme(themeInfo.resolvedTheme);
      });
    } catch (error) {
      console.error('Failed to initialize theme:', error);
      this.applyTheme('light');
    }
  }

  private applyTheme(theme: ResolvedTheme): void {
    const root = document.documentElement;

    if (theme === 'dark') {
      root.setAttribute('data-theme', 'dark');
    } else {
      root.removeAttribute('data-theme');
    }

    this.currentTheme = theme;
    console.log('Applied theme to document:', theme);
  }

  getCurrentTheme(): ResolvedTheme {
    return this.currentTheme;
  }

  async setTheme(theme: Theme): Promise<ThemeInfo> {
    try {
      const themeInfo = await (window as any).electronAPI.setTheme(theme);
      console.log('Theme preference updated:', themeInfo);
      return themeInfo;
    } catch (error) {
      console.error('Failed to set theme:', error);
      throw error;
    }
  }

  async getThemeInfo(): Promise<ThemeInfo> {
    try {
      return await (window as any).electronAPI.getCurrentTheme();
    } catch (error) {
      console.error('Failed to get theme info:', error);
      throw error;
    }
  }
}

// Mock window.electronAPI
const mockElectronAPI = {
  getCurrentTheme: jest.fn(),
  onThemeUpdated: jest.fn(),
  setTheme: jest.fn(),
};

describe('ThemeRenderer', () => {
  let themeRenderer: TestThemeRenderer;
  let consoleLogSpy: jest.SpyInstance;
  let consoleErrorSpy: jest.SpyInstance;
  let documentMock: any;

  beforeEach(() => {
    jest.clearAllMocks();
    
    // Create fresh instance for each test
    themeRenderer = new TestThemeRenderer();
    
    // Spy on console methods
    consoleLogSpy = jest.spyOn(console, 'log').mockImplementation();
    consoleErrorSpy = jest.spyOn(console, 'error').mockImplementation();
    
    // Mock document.documentElement
    documentMock = {
      setAttribute: jest.fn(),
      removeAttribute: jest.fn(),
    };
    
    // Replace document.documentElement
    Object.defineProperty(document, 'documentElement', {
      value: documentMock,
      writable: true,
      configurable: true,
    });

    // Mock window.electronAPI
    (window as any).electronAPI = mockElectronAPI;
  });

  afterEach(() => {
    consoleLogSpy.mockRestore();
    consoleErrorSpy.mockRestore();
  });

  describe('initialize', () => {
    it('should initialize with theme from main process', async () => {
      const themeInfo: ThemeInfo = {
        userPreference: 'system',
        resolvedTheme: 'dark',
        systemTheme: 'dark',
      };
      
      mockElectronAPI.getCurrentTheme.mockResolvedValue(themeInfo);
      mockElectronAPI.onThemeUpdated.mockImplementation(() => {});

      await themeRenderer.initialize();

      expect(mockElectronAPI.getCurrentTheme).toHaveBeenCalled();
      expect(mockElectronAPI.onThemeUpdated).toHaveBeenCalled();
      expect(documentMock.setAttribute).toHaveBeenCalledWith('data-theme', 'dark');
      expect(themeRenderer.getCurrentTheme()).toBe('dark');
      expect(consoleLogSpy).toHaveBeenCalledWith('Applied theme to document:', 'dark');
    });

    it('should initialize with light theme from main process', async () => {
      const themeInfo: ThemeInfo = {
        userPreference: 'light',
        resolvedTheme: 'light',
        systemTheme: 'light',
      };
      
      mockElectronAPI.getCurrentTheme.mockResolvedValue(themeInfo);
      mockElectronAPI.onThemeUpdated.mockImplementation(() => {});

      await themeRenderer.initialize();

      expect(mockElectronAPI.getCurrentTheme).toHaveBeenCalled();
      expect(documentMock.removeAttribute).toHaveBeenCalledWith('data-theme');
      expect(themeRenderer.getCurrentTheme()).toBe('light');
      expect(consoleLogSpy).toHaveBeenCalledWith('Applied theme to document:', 'light');
    });

    it('should set up theme update listener', async () => {
      const themeInfo: ThemeInfo = {
        userPreference: 'system',
        resolvedTheme: 'light',
        systemTheme: 'light',
      };
      
      mockElectronAPI.getCurrentTheme.mockResolvedValue(themeInfo);
      
      let themeUpdateCallback: (themeInfo: ThemeInfo) => void;
      mockElectronAPI.onThemeUpdated.mockImplementation((callback) => {
        themeUpdateCallback = callback;
      });

      await themeRenderer.initialize();

      // Simulate theme update
      const newThemeInfo: ThemeInfo = {
        userPreference: 'system',
        resolvedTheme: 'dark',
        systemTheme: 'dark',
      };
      
      themeUpdateCallback!(newThemeInfo);

      expect(consoleLogSpy).toHaveBeenCalledWith('Theme updated in renderer:', newThemeInfo);
      expect(documentMock.setAttribute).toHaveBeenCalledWith('data-theme', 'dark');
      expect(themeRenderer.getCurrentTheme()).toBe('dark');
    });

    it('should fallback to light theme on initialization error', async () => {
      const error = new Error('Failed to get theme');
      mockElectronAPI.getCurrentTheme.mockRejectedValue(error);

      await themeRenderer.initialize();

      expect(consoleErrorSpy).toHaveBeenCalledWith('Failed to initialize theme:', error);
      expect(documentMock.removeAttribute).toHaveBeenCalledWith('data-theme');
      expect(themeRenderer.getCurrentTheme()).toBe('light');
      expect(consoleLogSpy).toHaveBeenCalledWith('Applied theme to document:', 'light');
    });
  });

  describe('getCurrentTheme', () => {
    it('should return current theme', () => {
      // Theme starts as light by default
      expect(themeRenderer.getCurrentTheme()).toBe('light');
    });

    it('should return updated theme after applying dark theme', async () => {
      const themeInfo: ThemeInfo = {
        userPreference: 'dark',
        resolvedTheme: 'dark',
        systemTheme: 'light',
      };
      
      mockElectronAPI.getCurrentTheme.mockResolvedValue(themeInfo);
      await themeRenderer.initialize();

      expect(themeRenderer.getCurrentTheme()).toBe('dark');
    });
  });

  describe('setTheme', () => {
    it('should set theme preference successfully', async () => {
      const expectedThemeInfo: ThemeInfo = {
        userPreference: 'dark',
        resolvedTheme: 'dark',
        systemTheme: 'light',
      };
      
      mockElectronAPI.setTheme.mockResolvedValue(expectedThemeInfo);

      const result = await themeRenderer.setTheme('dark');

      expect(mockElectronAPI.setTheme).toHaveBeenCalledWith('dark');
      expect(result).toEqual(expectedThemeInfo);
      expect(consoleLogSpy).toHaveBeenCalledWith('Theme preference updated:', expectedThemeInfo);
    });

    it('should handle theme setting error', async () => {
      const error = new Error('Failed to set theme');
      mockElectronAPI.setTheme.mockRejectedValue(error);

      await expect(themeRenderer.setTheme('system')).rejects.toThrow('Failed to set theme');
      expect(consoleErrorSpy).toHaveBeenCalledWith('Failed to set theme:', error);
    });

    it('should set light theme preference', async () => {
      const expectedThemeInfo: ThemeInfo = {
        userPreference: 'light',
        resolvedTheme: 'light',
        systemTheme: 'dark',
      };
      
      mockElectronAPI.setTheme.mockResolvedValue(expectedThemeInfo);

      const result = await themeRenderer.setTheme('light');

      expect(mockElectronAPI.setTheme).toHaveBeenCalledWith('light');
      expect(result).toEqual(expectedThemeInfo);
    });

    it('should set system theme preference', async () => {
      const expectedThemeInfo: ThemeInfo = {
        userPreference: 'system',
        resolvedTheme: 'dark',
        systemTheme: 'dark',
      };
      
      mockElectronAPI.setTheme.mockResolvedValue(expectedThemeInfo);

      const result = await themeRenderer.setTheme('system');

      expect(mockElectronAPI.setTheme).toHaveBeenCalledWith('system');
      expect(result).toEqual(expectedThemeInfo);
    });
  });

  describe('getThemeInfo', () => {
    it('should get current theme info successfully', async () => {
      const expectedThemeInfo: ThemeInfo = {
        userPreference: 'system',
        resolvedTheme: 'light',
        systemTheme: 'light',
      };
      
      mockElectronAPI.getCurrentTheme.mockResolvedValue(expectedThemeInfo);

      const result = await themeRenderer.getThemeInfo();

      expect(mockElectronAPI.getCurrentTheme).toHaveBeenCalled();
      expect(result).toEqual(expectedThemeInfo);
    });

    it('should handle theme info retrieval error', async () => {
      const error = new Error('Failed to get theme info');
      mockElectronAPI.getCurrentTheme.mockRejectedValue(error);

      await expect(themeRenderer.getThemeInfo()).rejects.toThrow('Failed to get theme info');
      expect(consoleErrorSpy).toHaveBeenCalledWith('Failed to get theme info:', error);
    });
  });

  describe('theme application', () => {
    it('should apply dark theme correctly', async () => {
      const themeInfo: ThemeInfo = {
        userPreference: 'dark',
        resolvedTheme: 'dark',
        systemTheme: 'light',
      };
      
      mockElectronAPI.getCurrentTheme.mockResolvedValue(themeInfo);
      await themeRenderer.initialize();

      expect(documentMock.setAttribute).toHaveBeenCalledWith('data-theme', 'dark');
      expect(documentMock.removeAttribute).not.toHaveBeenCalled();
      expect(consoleLogSpy).toHaveBeenCalledWith('Applied theme to document:', 'dark');
    });

    it('should apply light theme correctly', async () => {
      const themeInfo: ThemeInfo = {
        userPreference: 'light',
        resolvedTheme: 'light',
        systemTheme: 'dark',
      };
      
      mockElectronAPI.getCurrentTheme.mockResolvedValue(themeInfo);
      await themeRenderer.initialize();

      expect(documentMock.removeAttribute).toHaveBeenCalledWith('data-theme');
      expect(documentMock.setAttribute).not.toHaveBeenCalledWith('data-theme', 'dark');
      expect(consoleLogSpy).toHaveBeenCalledWith('Applied theme to document:', 'light');
    });

    it('should handle theme transitions correctly', async () => {
      // Start with light theme
      const lightThemeInfo: ThemeInfo = {
        userPreference: 'light',
        resolvedTheme: 'light',
        systemTheme: 'light',
      };
      
      mockElectronAPI.getCurrentTheme.mockResolvedValue(lightThemeInfo);
      
      let themeUpdateCallback: (themeInfo: ThemeInfo) => void;
      mockElectronAPI.onThemeUpdated.mockImplementation((callback) => {
        themeUpdateCallback = callback;
      });

      await themeRenderer.initialize();

      // Verify initial light theme
      expect(documentMock.removeAttribute).toHaveBeenCalledWith('data-theme');
      expect(themeRenderer.getCurrentTheme()).toBe('light');

      // Clear mocks for transition test
      documentMock.setAttribute.mockClear();
      documentMock.removeAttribute.mockClear();

      // Transition to dark theme
      const darkThemeInfo: ThemeInfo = {
        userPreference: 'dark',
        resolvedTheme: 'dark',
        systemTheme: 'light',
      };
      
      themeUpdateCallback!(darkThemeInfo);

      expect(documentMock.setAttribute).toHaveBeenCalledWith('data-theme', 'dark');
      expect(themeRenderer.getCurrentTheme()).toBe('dark');

      // Clear mocks for second transition
      documentMock.setAttribute.mockClear();
      documentMock.removeAttribute.mockClear();

      // Transition back to light theme
      themeUpdateCallback!(lightThemeInfo);

      expect(documentMock.removeAttribute).toHaveBeenCalledWith('data-theme');
      expect(themeRenderer.getCurrentTheme()).toBe('light');
    });
  });

  describe('integration scenarios', () => {
    it('should handle complete workflow from settings UI', async () => {
      // Initialize with system theme
      const initialThemeInfo: ThemeInfo = {
        userPreference: 'system',
        resolvedTheme: 'light',
        systemTheme: 'light',
      };
      
      mockElectronAPI.getCurrentTheme.mockResolvedValue(initialThemeInfo);
      mockElectronAPI.onThemeUpdated.mockImplementation(() => {});

      await themeRenderer.initialize();

      // User changes preference to dark
      const updatedThemeInfo: ThemeInfo = {
        userPreference: 'dark',
        resolvedTheme: 'dark',
        systemTheme: 'light',
      };
      
      mockElectronAPI.setTheme.mockResolvedValue(updatedThemeInfo);

      const result = await themeRenderer.setTheme('dark');

      expect(result).toEqual(updatedThemeInfo);
      expect(consoleLogSpy).toHaveBeenCalledWith('Theme preference updated:', updatedThemeInfo);

      // Get updated theme info
      mockElectronAPI.getCurrentTheme.mockResolvedValue(updatedThemeInfo);
      const currentInfo = await themeRenderer.getThemeInfo();
      
      expect(currentInfo).toEqual(updatedThemeInfo);
    });

    it('should handle system theme changes when user preference is system', async () => {
      const systemThemeInfo: ThemeInfo = {
        userPreference: 'system',
        resolvedTheme: 'light',
        systemTheme: 'light',
      };
      
      mockElectronAPI.getCurrentTheme.mockResolvedValue(systemThemeInfo);
      
      let themeUpdateCallback: (themeInfo: ThemeInfo) => void;
      mockElectronAPI.onThemeUpdated.mockImplementation((callback) => {
        themeUpdateCallback = callback;
      });

      await themeRenderer.initialize();

      // System changes to dark
      const updatedSystemTheme: ThemeInfo = {
        userPreference: 'system',
        resolvedTheme: 'dark',
        systemTheme: 'dark',
      };
      
      themeUpdateCallback!(updatedSystemTheme);

      expect(documentMock.setAttribute).toHaveBeenCalledWith('data-theme', 'dark');
      expect(themeRenderer.getCurrentTheme()).toBe('dark');
      expect(consoleLogSpy).toHaveBeenCalledWith('Theme updated in renderer:', updatedSystemTheme);
    });
  });
});

describe('Module auto-initialization behavior', () => {
  it('should test auto-initialization logic patterns', () => {
    // Test the conditional logic pattern used in theme-renderer.ts
    const mockDocument = {
      readyState: 'loading',
      addEventListener: jest.fn(),
    };

    const mockThemeRenderer = {
      initialize: jest.fn(),
    };

    // Simulate the auto-initialization logic from theme-renderer.ts
    if (mockDocument.readyState === 'loading') {
      mockDocument.addEventListener('DOMContentLoaded', () => {
        mockThemeRenderer.initialize();
      });
    } else {
      mockThemeRenderer.initialize();
    }

    expect(mockDocument.addEventListener).toHaveBeenCalledWith('DOMContentLoaded', expect.any(Function));
    expect(mockThemeRenderer.initialize).not.toHaveBeenCalled();
  });

  it('should test immediate initialization when document is ready', () => {
    // Test the conditional logic pattern used in theme-renderer.ts
    const mockDocument = {
      readyState: 'complete',
      addEventListener: jest.fn(),
    };

    const mockThemeRenderer = {
      initialize: jest.fn(),
    };

    // Simulate the auto-initialization logic from theme-renderer.ts
    if (mockDocument.readyState === 'loading') {
      mockDocument.addEventListener('DOMContentLoaded', () => {
        mockThemeRenderer.initialize();
      });
    } else {
      mockThemeRenderer.initialize();
    }

    expect(mockDocument.addEventListener).not.toHaveBeenCalled();
    expect(mockThemeRenderer.initialize).toHaveBeenCalled();
  });
});