/**
 * @file Jest configuration for coverage reporting
 * Enforces 90% coverage target for new features
 */

export default {
  preset: 'ts-jest',
  testEnvironment: 'jsdom',
  setupFilesAfterEnv: ['<rootDir>/test/setup.ts'],
  collectCoverage: true,
  coverageDirectory: 'coverage',
  coverageReporters: ['text', 'lcov', 'html'],

  // Current coverage thresholds - targeting gradual improvement
  coverageThreshold: {
    global: {
      branches: 35, // Current: 33.81%
      functions: 37, // Current: 36.17%
      lines: 41, // Current: 40.29%
      statements: 41, // Current: 40.15%
    },
  },

  // Files to collect coverage from
  collectCoverageFrom: [
    'app/**/*.ts',
    '!app/**/*.d.ts',
    '!app/**/*.test.ts',
    '!app/**/*.spec.ts',
    // Exclude renderer files (run in different context)
    '!app/renderer.ts',
    '!app/renderer-wrapper.ts',
    '!app/theme-renderer.ts',
  ],

  // Test match patterns
  testMatch: ['**/__tests__/**/*.ts?(x)', '**/?(*.)+(spec|test).ts?(x)'],

  // Prevent worker hanging
  maxWorkers: 1,
  detectOpenHandles: true,
  forceExit: true,
  testTimeout: 10000,
};
