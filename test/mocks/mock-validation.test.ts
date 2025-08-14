/**
 * @file Tests to validate that our mock implementations work correctly
 */

// Import the mocks directly to avoid path resolution issues
const MockBagItFs = require('./__mocks__/bagit-fs.js');
const MockEleventy = require('./__mocks__/eleventy.js');
const MockEleventyDevServer = require('./__mocks__/eleventy-dev-server.js');

describe('Mock File Validation', () => {
  describe('BagIt Mock', () => {
    it('should provide all required BagIt methods', () => {
      const mockInstance = MockBagItFs();

      expect(mockInstance).toHaveProperty('createWriteStream');
      expect(mockInstance).toHaveProperty('mkdir');
      expect(mockInstance).toHaveProperty('finalize');

      expect(typeof mockInstance.createWriteStream).toBe('function');
      expect(typeof mockInstance.mkdir).toBe('function');
      expect(typeof mockInstance.finalize).toBe('function');
    });

    it('should create write stream with proper interface', () => {
      const mockInstance = MockBagItFs();

      const writeStream = mockInstance.createWriteStream('/test/path');

      expect(writeStream).toHaveProperty('on');
      expect(writeStream).toHaveProperty('write');
      expect(writeStream).toHaveProperty('end');

      expect(typeof writeStream.on).toBe('function');
      expect(typeof writeStream.write).toBe('function');
      expect(typeof writeStream.end).toBe('function');
    });

    it('should handle mkdir with callback', () => {
      const mockInstance = MockBagItFs();

      const callback = jest.fn();
      mockInstance.mkdir('/test/dir', callback);

      expect(callback).toHaveBeenCalled();
    });

    it('should handle finalize with callback', () => {
      const mockInstance = MockBagItFs();

      const callback = jest.fn();
      mockInstance.finalize(callback);

      expect(callback).toHaveBeenCalled();
    });
  });

  describe('Eleventy Mock', () => {
    it('should provide all required Eleventy methods', () => {
      const mockInstance = new MockEleventy();

      expect(mockInstance).toHaveProperty('write');
      expect(mockInstance).toHaveProperty('watch');
      expect(mockInstance).toHaveProperty('serve');

      expect(typeof mockInstance.write).toBe('function');
      expect(typeof mockInstance.watch).toBe('function');
      expect(typeof mockInstance.serve).toBe('function');
    });

    it('should have async methods that can be called', () => {
      const mockInstance = new MockEleventy();

      // Just verify the methods exist and can be called without error
      expect(() => mockInstance.write()).not.toThrow();
      expect(() => mockInstance.serve()).not.toThrow();
    });
  });

  describe('Eleventy Dev Server Mock', () => {
    it('should provide all required dev server methods', () => {
      const mockInstance = new MockEleventyDevServer();

      expect(mockInstance).toHaveProperty('serve');
      expect(mockInstance).toHaveProperty('close');
      expect(mockInstance).toHaveProperty('watchFiles');
      expect(mockInstance).toHaveProperty('watcher');

      expect(typeof mockInstance.serve).toBe('function');
      expect(typeof mockInstance.close).toBe('function');
      expect(typeof mockInstance.watchFiles).toBe('function');
    });

    it('should have async methods that can be called', () => {
      const mockInstance = new MockEleventyDevServer();

      // Just verify the methods exist and can be called without error
      expect(() => mockInstance.serve()).not.toThrow();
      expect(() => mockInstance.close()).not.toThrow();
    });

    it('should provide watcher interface', () => {
      const mockInstance = new MockEleventyDevServer();

      expect(mockInstance.watcher).toHaveProperty('on');
      expect(mockInstance.watcher).toHaveProperty('close');

      expect(typeof mockInstance.watcher.on).toBe('function');
      expect(typeof mockInstance.watcher.close).toBe('function');
    });

    it('should have watchFiles method that can be called', () => {
      const mockInstance = new MockEleventyDevServer();

      // Just verify the method exists and can be called without error
      expect(() => mockInstance.watchFiles()).not.toThrow();
    });
  });

  describe('Mock Integration', () => {
    it('should work with Jest mocking system', () => {
      // Test that our mocks integrate properly with Jest
      // Should not throw errors when imported
      expect(() => {
        MockBagItFs();
        new MockEleventy();
        new MockEleventyDevServer();
      }).not.toThrow();
    });
  });
});
