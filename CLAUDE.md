# Gemini Project Notes for Anglesite

This document contains notes and learned information about the Anglesite project, intended to assist future interactions and maintain context.

## Project Structure & Key Directories

- `app/`: Contains the Electron application source code (TypeScript files).
- `src/`: Contains the Eleventy static site content source (e.g., Markdown files).
- `dist/`: Contains the compiled output from both the Electron application (`dist/app/`) and the Eleventy build (`dist/`).
- `docs/`: Project documentation (e.g., `plan.md`, `requirements.md`).
- `test/`: Contains unit tests for the application.

## Key Technologies & Versions

- **Electron:** (version specified in `package.json`) - Used for the desktop application shell.
- **Eleventy (`@11ty/eleventy`):** (version specified in `package.json`) - Static site generator. Configured via `.eleventy.ts`.
- **TypeScript:** (version specified in `package.json`) - Primary language for application and configuration files.
- **ESLint:** `v8.x` - Used for linting. **Note:** Reverted from v9 due to persistent issues with its new flat config system and `typescript-eslint` module resolution. Configuration is in `.eslintrc.cjs`.
- **Prettier:** `v2.x` - Used for code formatting. Compatible with ESLint v8 setup.
- **Jest:** (version specified in `package.json`) - Testing framework. Uses `ts-jest` for TypeScript and `jest-environment-jsdom` for DOM-related tests.
- **`live-server`:** (version specified in `package.json`) - Used for local preview of Eleventy build output within the Electron app.

## Important Scripts

- `npm run build`: Compiles the Eleventy site.
- `npm run lint`: Runs ESLint for linting TypeScript files.
- `npm run format`: Runs Prettier for code formatting.
- `npm run test`: Executes Jest tests.
- `npm start`: Launches the Electron application.

## Specific Configurations & Workarounds

- **ESLint Configuration:**
  - Uses `eslint.config.cjs` (CommonJS flat config format) compatible with ESLint v9.
  - Successfully migrated from ESLint v8 legacy configuration to ESLint v9 flat config system.
  - TypeScript-ESLint v8.39.0+ provides full ESLint v9 support.
- **Jest Test Environment:**
  - `jest.config.ts` is configured to use `jsdom` for tests that interact with the DOM (e.g., `test/renderer.test.ts`).
  - `jest-environment-jsdom` is installed as a separate dependency.
- **Electron Main Process Testing (`test/main.test.ts`):**
  - Complex mocking of Electron's `app`, `BrowserWindow`, and `ipcMain` is in place.
  - `app.on` and `app.emit` mocks are custom-implemented to simulate event listeners and emissions for testing purposes.
  - `child_process` functions (`exec`, `spawn`) are mocked.
  - `no-explicit-any` rule is disabled for this test file due to the complexity of mocking Electron's API.
- **TypeScript Declaration Files:**
  - `dist/app/main.d.ts` and `dist/app/renderer.d.ts` were created to resolve TypeScript errors when importing compiled JavaScript files in tests.
  - `/// <reference types="node" />` was considered for `renderer.test.ts` but `jest.requireActual` was used instead.

## Development Workflow Notes

- **TypeScript Compilation:** `npx tsc` is used to compile TypeScript files, which are prefered over JavaScript.
- **Testing Strategy:** Tests are written for Eleventy configuration, Electron main process logic (including `live-server` management and build triggering), and renderer process interactions.
- **JSDoc:** Full JSDoc comments have been added to all TypeScript files.
- **Node Packages:** When adding features use NPM packages rather than shell scripts or AppleScripts. This is especially true when there are NPM packages tagged 'electron' that will solve a problem.
