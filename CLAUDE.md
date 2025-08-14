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
- **ESLint:** `v9.x` - Used for linting. **Note:** Configuration is in `.eslint.config.cjs`. Avoid useing eslint-disable directives.
- **Prettier:** `v2.x` - Used for code formatting. Compatible with ESLint v9 setup.
- **Jest:** (version specified in `package.json`) - Testing framework. Uses `ts-jest` for TypeScript and `jest-environment-jsdom` for DOM-related tests.
- **`live-server`:** (version specified in `package.json`) - Used for local preview of Eleventy build output within the Electron app.

## Important Scripts

- `npm run build:app`: Compiles the Electron application.
- `npm run lint`: Runs Prettier for code formatting and then ESLint for linting TypeScript files.
- `npm run test:coverage`: Executes Jest tests.
- `npm start`: Launches the Electron application.

## Specific Configurations & Workarounds

- **ESLint Configuration:**
  - Uses `eslint.config.cjs` (CommonJS flat config format) compatible with ESLint v9.
- **Jest Test Environment:**
  - `jest.config.ts` is configured to use `jsdom` for tests that interact with the DOM (e.g., `test/renderer.test.ts`).
  - `jest-environment-jsdom` is installed as a separate dependency.
- **Electron Main Process Testing (`test/main.test.ts`):**
  - Complex mocking of Electron's `app`, `BrowserWindow`, and `ipcMain` is in place.
  - `app.on` and `app.emit` mocks are custom-implemented to simulate event listeners and emissions for testing purposes.
  - `child_process` functions (`exec`, `spawn`) are mocked.s
- **TypeScript Declaration Files:**
  - `dist/app/main.d.ts` and `dist/app/renderer.d.ts` were created to resolve TypeScript errors when importing compiled JavaScript files in tests.
  - `/// <reference types="node" />` was considered for `renderer.test.ts` but `jest.requireActual` was used instead.

## Development Workflow Notes

- **TypeScript Compilation:** `npx tsc` is used to compile TypeScript files.
- **Testing Strategy:** Tests are written in the AAA pattern for all code files with an expected coverage of 90% for statments, branches, lines, and functions. Use `npm run test:coverage` when running tests.
- **JSDoc:** Full JSDoc comments have been added to all TypeScript files. Make heavy use of `@see` directives to link to the offical documentation or RFC.
- **Node Packages:** When adding features use NPM packages when availible for logic, API bridges, and cross-platform user experiences.
