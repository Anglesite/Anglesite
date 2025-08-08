/**
 * @file Jest setup file for renderer tests
 */

// Mock electronAPI globally for all tests
const mockElectronAPI = {
  send: jest.fn(),
  on: jest.fn(),
  removeAllListeners: jest.fn(),
};

// Set up window.electronAPI for renderer tests
Object.defineProperty(window, "electronAPI", {
  value: mockElectronAPI,
  writable: true,
});

// Export for tests that need direct access
(
  global as unknown as { mockElectronAPI: typeof mockElectronAPI }
).mockElectronAPI = mockElectronAPI;
