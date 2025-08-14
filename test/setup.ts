/**
 * @file Jest setup file for renderer tests
 */

// Import custom matchers to make them available in all test files
import './matchers/custom-matchers';

// Import third-party mocks to ensure they're applied early
import './mocks/third-party';

// Setup TextEncoder/TextDecoder for JSDOM
if (typeof global.TextEncoder === 'undefined') {
  const { TextEncoder, TextDecoder } = require('util');
  global.TextEncoder = TextEncoder;
  global.TextDecoder = TextDecoder;
}

// Mock electronAPI globally for all tests
const mockElectronAPI = {
  send: jest.fn(),
  on: jest.fn(),
  removeAllListeners: jest.fn(),
};

// Set up window.electronAPI for renderer tests
Object.defineProperty(window, 'electronAPI', {
  value: mockElectronAPI,
  writable: true,
});

// Export for tests that need direct access
(global as unknown as { mockElectronAPI: typeof mockElectronAPI }).mockElectronAPI = mockElectronAPI;
