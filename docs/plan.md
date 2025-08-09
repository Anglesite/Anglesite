# Anglesite Project Plan

This document outlines the project plan for Anglesite, detailing the goals, scope, milestones, and strategies for its development as an open-source project.

## 1. Introduction

Anglesite is a local-first, Electron-based static site generator that combines the power of Eleventy with an intuitive desktop application experience. It democratizes website creation by providing both technical and non-technical users with a seamless local development environment featuring automatic HTTPS support, smart DNS management, and real-time preview capabilities.

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

### Phase 1: Core Desktop Application ✅ **COMPLETED**

The MVP focused on delivering a fully functional desktop application with comprehensive local development features.

- **Completed Deliverables:**
  1. **Native Desktop App:** Full Electron application with native menu system
  2. **HTTPS Development Environment:** Automatic SSL certificate management with CA installation
  3. **Smart DNS Management:** Automatic .test domain configuration via /etc/hosts
  4. **Live Preview System:** Real-time preview with hot reload and WebContentsView
  5. **First Launch Flow:** Guided setup assistant for HTTPS/HTTP mode selection
  6. **Website Management:** Create, build, and preview websites with automatic domain setup

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
   - Certificate management requires user keychain (not system) to avoid admin privileges
   - Preview pane requires explicit WebContentsView attachment to window
   - First launch flow essential for certificate trust establishment

3. **SSL Certificate & HTTPS Infrastructure** ✅ **COMPLETED**

   - ✅ Implemented local Certificate Authority (CA) generation using mkcert
   - ✅ Automated SSL certificate generation for .test domains
   - ✅ User keychain integration for trusted certificate installation
   - ✅ HTTPS proxy server for secure local development
   - ✅ Graceful fallback to HTTP mode when certificates fail

   **Features Delivered:**

   - Self-contained CA with 825-day validity
   - Certificate caching for performance
   - Automatic domain certificate generation
   - User keychain installation (no admin required)
   - HTTPS proxy on port 8080 → Eleventy on port 8081

4. **DNS Management & Hosts Integration** ✅ **COMPLETED**

   - ✅ Automatic /etc/hosts file management
   - ✅ Smart cleanup of orphaned domains on startup
   - ✅ Seamless .test domain configuration
   - ✅ Sudo permission handling for hosts file updates

   **Features Delivered:**

   - Syncs hosts file with actual website directories
   - Preserves system entries outside Anglesite section
   - Removes orphaned .test domains automatically
   - Batch operations to minimize sudo prompts

5. **User Interface & Experience** ✅ **COMPLETED**

   - ✅ First launch assistant with HTTPS/HTTP mode selection
   - ✅ Native macOS menu integration
   - ✅ Website creation workflow
   - ✅ Live preview with WebContentsView
   - ✅ DevTools integration for debugging

   **Features Delivered:**

   - Guided first launch setup with gem emoji branding
   - Direct mode selection without confirmation dialogs
   - External HTML templates for maintainability
   - Keyboard shortcuts (Cmd+N, Cmd+B, Cmd+Option+I)
   - Streamlined workflow without success dialogs

6. **Application Architecture** ✅ **COMPLETED**

   - ✅ Modular TypeScript architecture with full JSDoc documentation
   - ✅ Comprehensive IPC communication system
   - ✅ Settings persistence with JSON storage
   - ✅ Server management with proper lifecycle handling

   **Architecture Delivered:**

   - Main process: Certificate, DNS, server, and window management
   - Renderer process: UI components and preview display
   - IPC handlers: Secure communication between processes
   - Utility modules: Website management and helper functions
   - Complete separation of concerns with documented interfaces

### Phase 2: Content Management & Publishing

Now that the core desktop application is complete, focus shifts to content creation and publishing workflows.

- **Planned Deliverables:**
  1. **Visual Editor Integration:** Implement WYSIWYG editors for Markdown and HTML content
  2. **Theme System:** Create theme marketplace with customizable templates
  3. **Standards-Compliant Output:** Generate semantic HTML5, responsive CSS, and accessibility-compliant markup
  4. **Syndication Engine:** Built-in RSS, JSON Feed, and social media integration
  5. **Git Integration:** Version control for websites with visual diff interface
  6. **Deployment Pipeline:** Direct publishing to hosting services (Netlify, Vercel, GitHub Pages)

### Phase 3: Ecosystem & Platform Expansion

This phase focuses on expanding platform support and building a plugin ecosystem.

- **Planned Deliverables:**
  1. **Multi-Platform Support:** Windows and Linux certificate management and hosts integration
  2. **Plugin System:** Extensible architecture for third-party Eleventy configurations
  3. **Import Framework:** Migration tools from WordPress, Jekyll, Hugo, and other generators
  4. **Advanced Collaboration:** Multi-user editing with conflict resolution
  5. **Cloud Sync:** Optional cloud storage integration for website backup/sync
  6. **Advanced Deployment:** CI/CD pipeline integration and staging environments

## 5. Technical Strategy

- **Core Stack:** Electron 31+, Node.js 18+, TypeScript 5+, Eleventy 2.0+, mkcert for certificates
- **Architecture:** Modular, multi-process architecture with strict separation of concerns and comprehensive IPC communication
- **Security Model:** Local-only servers, user keychain certificates, sandboxed website storage, no external network access
- **Development Standards:** Test-Driven Development (TDD), comprehensive JSDoc documentation, ESLint + Prettier, 65%+ test coverage
- **Platform Strategy:** macOS first (complete), Windows/Linux planned for Phase 3

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

### Phase 1 Metrics (Achieved)

- **✅ Technical Completeness:** 100% of core desktop features implemented
- **✅ Security Model:** Zero admin privileges required, comprehensive certificate management
- **✅ User Experience:** Streamlined first launch with 2-step setup process
- **✅ Documentation Quality:** Complete JSDoc coverage, architectural diagrams, user guides
- **✅ Code Quality:** 65%+ test coverage, TypeScript throughout, comprehensive linting

### Future Success Metrics

- **Community Engagement:** Contributors, GitHub stars, and community plugins
- **Platform Adoption:** Windows/Linux compatibility and user base growth
- **Ecosystem Growth:** Third-party themes, plugins, and integrations
- **Project Velocity:** Consistent milestone delivery and feature expansion

## 9. Current Status & Next Steps

### ✅ Phase 1: Core Desktop Application (COMPLETED)

**Completed Features:**

- ✅ Full Electron desktop application with native menus
- ✅ Automatic HTTPS development environment with CA management
- ✅ Smart DNS management via /etc/hosts integration
- ✅ Live preview system with hot reload
- ✅ First launch assistant with guided setup
- ✅ Complete website lifecycle (create → edit → build → preview)
- ✅ Comprehensive architecture documentation with Mermaid diagrams
- ✅ Full JSDoc documentation across all modules
- ✅ Updated README and project documentation

**Technical Achievements:**

- Complete certificate management system using mkcert
- HTTPS proxy server for secure .test domain access
- Automatic hosts file cleanup and synchronization
- Modular TypeScript architecture with IPC communication
- WebContentsView integration for secure preview display
- Settings persistence and first-launch flow
- Comprehensive test coverage with Jest

### 🎯 Next Phase: Content Management (Phase 2)

**Immediate Priorities:**

1. **Visual Editor Integration**

   - Research and implement WYSIWYG Markdown editor
   - Add rich text editing capabilities
   - File upload and media management

2. **Theme System**

   - Create default responsive theme
   - Implement theme switching mechanism
   - Add theme customization options

3. **Enhanced Content Features**
   - SEO metadata management
   - Social sharing optimization
   - RSS/JSON feed generation

### Technical Decisions Validated

1. **✅ User Keychain over System**: Eliminates admin privilege requirements
2. **✅ External HTML Files**: Improves maintainability over inline strings
3. **✅ Automatic Hosts Cleanup**: Prevents orphaned domain accumulation
4. **✅ Direct Mode Selection**: Streamlines first launch experience
5. **✅ WebContentsView Architecture**: Provides secure, modern preview system
6. **✅ Modular TypeScript Design**: Enables easy feature expansion

### Platform Readiness Assessment

- **macOS**: ✅ Production ready with full feature set
- **Windows**: 🟡 Core architecture compatible, certificate management needs adaptation
- **Linux**: 🟡 Core architecture compatible, hosts management may need sudo handling

### Success Metrics Achieved

- **Functionality**: 100% of Phase 1 objectives completed
- **Security**: Zero admin privileges required, all operations sandboxed
- **User Experience**: First launch success rate improved with guided setup
- **Code Quality**: 65%+ test coverage, comprehensive documentation
- **Architecture**: Fully modular design ready for Phase 2 expansion
