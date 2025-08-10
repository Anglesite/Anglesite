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

  // 90% coverage target for new features
  coverageThreshold: {
    global: {
      branches: 80, // Branches can be harder to cover completely
      functions: 90,
      lines: 90,
      statements: 90,
    },
    // Specific thresholds for dark mode feature files
    './app/ui/theme-manager.ts': {
      branches: 80,
      functions: 90,
      lines: 90,
      statements: 90,
    },
  },

  // Files to collect coverage from
  collectCoverageFrom: ['app/**/*.ts', '!app/**/*.d.ts', '!app/**/*.test.ts', '!app/**/*.spec.ts'],

  // Test match patterns
  testMatch: ['**/__tests__/**/*.ts?(x)', '**/?(*.)+(spec|test).ts?(x)'],
};
