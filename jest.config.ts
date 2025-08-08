/**
 * @file Jest configuration file.
 * @see {@link https://jestjs.io/docs/configuration}
 */
export default {
  preset: "ts-jest",
  transform: {
    "^.+.ts$": "ts-jest",
    "^.+.js$": "ts-jest",
  },
  testEnvironment: "jsdom",
  setupFilesAfterEnv: ["<rootDir>/test/setup.ts"],
  testMatch: ["**/__tests__/**/*.ts?(x)", "**/?(*.)+(spec|test).ts?(x)"],
  moduleNameMapper: {
    "^../../eleventy/.eleventy$": "<rootDir>/eleventy/.eleventy.js",
  },
};
