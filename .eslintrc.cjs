/**
 * @file ESLint configuration file.
 * @see {@link https://eslint.org/docs/latest/use/configure/configuration-files}
 *
 * This file is in CommonJS format (.cjs) due to persistent module resolution
 * issues encountered when attempting to use ESLint v9's flat configuration
 * with TypeScript and `typescript-eslint` in an ES module context.
 * The project currently uses ESLint v8 for stability.
 */
module.exports = {
  root: true,
  ignorePatterns: ["dist/**/*"],
  env: {
    node: true, // Enable Node.js global variables and Node.js scoping
  },
  parser: "@typescript-eslint/parser",
  plugins: ["@typescript-eslint", "prettier"],
  extends: [
    "eslint:recommended",
    "plugin:@typescript-eslint/recommended",
    "prettier",
  ],
  rules: {
    "prettier/prettier": "error",
  },
  overrides: [
    {
      files: ["**/*.js", "**/*.cjs"],
      parser: "espree", // Default parser for JavaScript
      parserOptions: {
        ecmaVersion: 2021,
        sourceType: "module",
      },
      extends: ["eslint:recommended", "prettier"],
      rules: {
        // Add any specific JavaScript rules here if needed
      },
    },
    {
      files: ["test/**/*.ts"],
      rules: {
        "@typescript-eslint/no-require-imports": "off",
      },
    },
  ],
};
