/**
 * @file Jest configuration file.
 * @see {@link https://jestjs.io/docs/configuration}
 */
export default {
  preset: 'ts-jest',
  transform: {
    '^.+.ts$': 'ts-jest',
    '^.+.js$': 'ts-jest',
  },
  testEnvironment: 'jsdom',
  setupFilesAfterEnv: ['<rootDir>/test/setup.ts'],
  testMatch: ['**/__tests__/**/*.ts?(x)', '**/?(*.)+(spec|test).ts?(x)'],
  moduleNameMapper: {
    '^../../app/eleventy/.eleventy$': '<rootDir>/app/eleventy/.eleventy.js',
    '^@11ty/eleventy$': '<rootDir>/test/mocks/__mocks__/eleventy.js',
    '^@11ty/eleventy-dev-server$': '<rootDir>/test/mocks/__mocks__/eleventy-dev-server.js',
    '^bagit-fs$': '<rootDir>/test/mocks/__mocks__/bagit-fs.js',
  },
  transformIgnorePatterns: ['node_modules/(?!(@11ty/eleventy|@11ty/eleventy-dev-server|bagit-fs)/)'],
  // Prevent worker hanging
  maxWorkers: 1,
  detectOpenHandles: true,
  forceExit: true,
  testTimeout: 10000,
};
