# Anglesite Project Plan

This document outlines the project plan for Anglesite, detailing the goals, scope, milestones, and strategies for its development as an open-source project.

## 1. Introduction

Anglesite is a local-first, open-source WYSIWYG static site generator built to democratize website creation. It empowers non-technical users to own and manage their web presence while offering extensibility and transparency for developers. The project is designed for active contribution and modular plugin development, with a focus on standards compliance, automation, and platform interoperability.

## 2. Project Goals & Objectives

The primary goals of the Anglesite project are to:

- Provide a developer-friendly open-source foundation for static website creation.
- Enable contributions through a robust plugin system and modular architecture.
- Prioritize standards compliance, accessibility, and automation.
- Facilitate multi-platform distribution and syndication.

## 3. Scope

### 3.1. In Scope

The project will focus on delivering the core features defined in the product requirements, including standards-compliant output, extensible visual editors, a syndication engine, and a developer-focused publishing workflow.

### 3.2. Out of Scope

To maintain focus, the following are explicitly out of scope:

- **Full-blown CMS features:** Anglesite will not include user management or a built-in database.
- **Proprietary platform development:** The project will remain fully open-source.
- **"One-size-fits-all" solutions:** The architecture will prioritize modularity and extensibility over monolithic design.

## 4. Milestones & Deliverables

Development will proceed in a phased approach to ensure a stable and scalable foundation.

### Phase 1: Minimum Viable Product (MVP)

The initial focus is on delivering a functional core product that provides a solid foundation for future development.

- **Deliverables:**
  1. **Standards-Compliant Output:** Generate semantic HTML, responsive CSS, and modern JS.
  2. **Extensible Visual Editors:** Implement modular WYSIWYG editors for HTML and Markdown.
  3. **Syndication Engine:** Include built-in support for RSS and JSONFeed.
  4. **Deployment Target:** Establish first-class support for Cloudflare Pages.
  5. **Electron UX:** Create a basic Electron shell with platform-native theming.

#### High-Level Task List (In Order)

1. **Foundation & Core Build Setup** ✅ **COMPLETED**

   - ✅ Initialize the Node.js project and install initial dependencies (11ty, TypeScript).
   - ✅ Establish the core directory structure (`src`, `dist`, `docs`).
   - ✅ Create a basic `.eleventy.js` configuration to build a single "Hello World" page.
   - ✅ Set up linting, formatting, and testing frameworks (e.g., ESLint, Prettier, Jest).

   **Lessons Learned:**

   - Used ESLint v8 instead of v9 due to compatibility issues with TypeScript and flat config
   - Implemented Nunjucks templates for better template inheritance
   - Added comprehensive JSDoc documentation throughout

2. **Basic Electron Shell** ✅ **COMPLETED**

   - ✅ Set up the main Electron process and a basic application window.
   - ✅ Create a simple renderer process UI to act as the application's front-end.
   - ✅ Integrate the 11ty build process, allowing it to be triggered from the Electron UI.
   - ✅ Embed a local preview server to display the generated site within the app.

   **Lessons Learned:**

   - Migrated from deprecated BrowserView to WebContentsView API for better security
   - Implemented strict Content Security Policy (CSP) without unsafe-inline
   - Switched from live-server to Eleventy's built-in server to avoid CSP violations
   - Added comprehensive test coverage (65%+ for main process)
   - Implemented proper process cleanup for server processes

3. **Standards-Compliant Output & Theming**

   - Develop a default theme using WebC templates that produces semantic HTML5.
   - Implement a CSS build pipeline for responsive design and accessibility.
   - Create data structures and templates for generating SEO metadata (schema.org, social cards).
   - Add automated accessibility checks (e.g., `axe-core`) to the test suite.

4. **Visual Editor Integration**

   - Research and select open-source WYSIWYG components for Markdown and HTML.
   - Develop the plugin wrapper API for editor components.
   - Integrate the selected Markdown and HTML editors into the Electron UI.

5. **Syndication Engine**

   - Create 11ty templates to generate RSS 2.0 and JSONFeed 1.1 feeds from content.
   - Ensure feeds are automatically updated during the build process.

6. **Deployment Workflow**
   - Create a Dockerfile to define a secure, sandboxed environment for running 11ty builds.
   - Develop a deployment plugin to automate publishing the output directory to Cloudflare Pages.
   - Document the end-to-end workflow: from creating content to deploying the site.

### Phase 2: Core Feature Expansion

Following the MVP, development will focus on expanding the core feature set to enhance functionality and developer experience.

- **Deliverables:**
  1. **Import & Migration Framework:** Build an abstracted importer pipeline for third-party platforms.
  2. **Developer-Focused Social Publishing:** Integrate git-centric content ownership with social platforms like BlueSky and Mastodon.
  3. **Modular Admin Console:** Develop a plugin-based UI with a default integration for Cloudflare.
  4. **Collaboration Infrastructure:** Implement Git-backed project storage with a visual diff UI and file watcher adapters.

### Phase 3: Community & Ecosystem Growth

This phase focuses on long-term growth by empowering contributors to expand the Anglesite ecosystem.

- **Deliverables (based on contributor roadmap):**
  1. **Internationalization (i18n/l10n):** Refactor for language pack support.
  2. **Headless CMS Sync:** Add integration points for external databases and headless CMS providers.
  3. **Serverless Support:** Create a Cloudflare Pages Functions plugin starter.
  4. **Expanded Export Templates:** Develop templates for SCORM, ePub, and Apple Help.

## 5. Technical Strategy

- **Stack:** Electron, Node.js, TypeScript, 11ty, and Docker.
- **Architecture:** A modular, plugin-driven architecture to encourage extensibility. UI and behavior will be extended via an Angular-style API.
- **Development Workflow:** A Test-Driven Development (TDD) approach will be used, with strict linting, formatting, and documentation standards (`JSDoc`).

## 6. Contribution & Collaboration

The project's success relies on community involvement.

- **Onboarding:** The `docs/requirements.md` file serves as the primary guide for new contributors.
- **Workflow:** Standard GitHub flow (fork, branch, pull request) will be used.
- **Standards:** All contributions must adhere to the technical standards outlined in the requirements, including TDD and JSDoc conventions.

## 7. Risks & Mitigation

| Risk                         | Mitigation                                                                                                                                                    |
| :--------------------------- | :------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Low Contributor Adoption** | Maintain high-quality documentation, a clear roadmap, and a welcoming environment. Actively engage with early contributors.                                   |
| **Scope Creep**              | Adhere strictly to the defined goals and phased rollout plan. Defer non-essential features to the post-MVP roadmap.                                           |
| **Technical Debt**           | Enforce strict TDD, linting, and code review processes. The modular plugin architecture helps isolate components and reduce complexity.                       |
| **Dependency Management**    | Rely on well-maintained open-source libraries. The plugin system allows for key components (like editors) to be swapped if a dependency becomes unmaintained. |

## 8. Success Metrics

Project success will be measured by:

- **Community Engagement:** Number of active contributors, forks, and stars.
- **Ecosystem Growth:** Number of third-party plugins and themes developed.
- **Adoption:** Number of websites built using Anglesite.
- **Project Velocity:** Consistent progress through the defined milestones.

## 9. Current Status & Next Steps

### Completed (Phase 1, Steps 1-2)

- ✅ Foundation & Core Build Setup (100%)
- ✅ Basic Electron Shell (100%)
- ✅ Basic UI implementation matching user-interface.md sketch
- ✅ Eleventy integration with live preview
- ✅ Comprehensive security implementation (CSP, secure IPC)

### In Progress (Phase 1, Step 3)

- **Standards-Compliant Output & Theming**
  - Next: Implement WebC templates for semantic HTML5
  - Next: Create responsive CSS pipeline
  - Next: Add SEO metadata generation

### Technical Decisions Made

1. **WebContentsView over BrowserView**: Better security and modern API
2. **Eleventy's built-in server**: Avoids CSP violations from script injection
3. **Strict CSP policy**: No unsafe-inline, enhances security
4. **TypeScript throughout**: Better type safety and documentation
5. **Comprehensive testing**: TDD approach with Jest

### Known Issues & Improvements

1. **Test Coverage**: Main process at 65%, could improve to 80%+
2. **Error Handling**: Need better user feedback for build errors
3. **UI Polish**: Current UI is functional but basic
4. **Documentation**: Need user-facing documentation beyond developer docs
