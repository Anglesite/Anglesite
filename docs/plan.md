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

### Phase 2: Content Management & WYSIWYG Editors

Now that the core desktop application foundation is complete, the focus shifts to implementing the core requirements for content creation and editing as defined in the requirements document.

- **Planned Deliverables (Aligned with Requirements):**
  1. **Extensible Visual Editors:** Modular WYSIWYG editors for HTML, Markdown, CSS, SVG, and XML
  2. **Standards-Compliant Output:** Semantic HTML5, responsive CSS, WCAG 2.1 AA accessibility compliance
  3. **Plugin System Foundation:** Angular-style API for UI and behavior extension
  4. **Editor Components:** Implementation of the editor matrix from requirements
  5. **Built-in SEO:** Structured metadata, schema.org, and social cards
  6. **Accessibility Integration:** Full OS-level accessibility APIs

**Editor Implementation Priority:**

1. **Markdown Editor:** CommonMark compliance with live preview
2. **HTML Editor:** HTML5 compliance with custom element integration
3. **CSS Editor:** W3C CSS compliance with visual design tools
4. **SVG Editor:** W3C SVG compliance with shape libraries
5. **XML Editor:** W3C XML compliance for syndication schema validation
6. **JavaScript/Text Editor:** VSCode-based with language extension plugins

### Phase 3: Syndication & Publishing Platform

This phase focuses on implementing the syndication engine and deployment infrastructure as specified in the requirements.

- **Planned Deliverables (Aligned with Requirements):**
  1. **Syndication Engine:** Built-in RSS, JSONFeed, and ActivityPub support
  2. **Import & Migration Framework:** WordPress, Wix, Jekyll, Hugo importers with domain verification
  3. **Developer-Focused Social Publishing:** Git-centric content with BlueSky/Mastodon integration
  4. **Deployment Targets:** First-class Cloudflare Pages support with plugin interface for other platforms
  5. **Modular Admin Console:** Plugin-powered UI with hosting provider integrations
  6. **Social Card Generation:** Customizable social media card creation and preview

### Phase 4: Collaboration & Multi-Platform

This phase expands platform support and implements collaboration features.

- **Planned Deliverables:**
  1. **Multi-Platform Support:** Windows and Linux certificate management and hosts integration
  2. **Collaboration Infrastructure:** Git-backed storage with visual diff UI
  3. **Cloud Storage Integration:** Dropbox/iCloud/Drive support via file watcher adapters
  4. **Real-time Collaboration:** Multi-user editing with conflict resolution
  5. **Advanced Deployment:** CI/CD pipeline integration and staging environments
  6. **Docker Integration:** Secure 11ty build execution in sandboxed environment

## 5. Technical Strategy (Aligned with Requirements)

- **Core Stack:** Electron + Node.js + TypeScript, 11ty as build engine, Docker for isolated builds, sudo-prompt for authentication
- **Architecture:** Modular plugin system with Angular-style API, multi-process Electron with comprehensive IPC
- **Plugin System Categories:**
  - CSS themes (based on community frameworks)
  - WebC templates
  - Build process middleware
  - Import/export adapters
  - Syndication integrations
  - Hosting/domain provider modules
- **Security & Configuration:**
  - Local-first with user keychain certificates
  - .env file encryption and OS password manager integration
  - All secrets excluded from version control by default
- **Development Standards:** TDD-first (CLI, UI, build outputs), TypeScript with strict linting, JSDoc with spec links
- **Editor Strategy:** Community-maintained NPM packages with editable plugin wrappers for contributor flexibility
- **Platform Strategy:** macOS foundation (complete), multi-platform expansion in Phase 4

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
- ✅ Smart DNS management via /etc/hosts integration with Touch ID support
- ✅ Live preview system with hot reload
- ✅ First launch assistant with guided setup
- ✅ Multi-window architecture for dedicated website editing
- ✅ Enhanced authentication system with biometric support
- ✅ Complete website lifecycle (create → edit → build → preview)
- ✅ Website management with validation, renaming, and deletion
- ✅ Comprehensive architecture documentation with Mermaid diagrams
- ✅ Full JSDoc documentation across all modules
- ✅ Updated README and project documentation

**Technical Achievements:**

- Complete certificate management system using mkcert
- HTTPS proxy server for secure .test domain access
- Enhanced authentication system with Touch ID/biometric support
- Modern privilege escalation using sudo-prompt (replaced electron-sudo)
- Multi-window architecture with dedicated website editing windows
- Automatic hosts file cleanup and synchronization
- Modular TypeScript architecture with comprehensive IPC communication
- WebContentsView integration for secure preview display
- Context-aware menu system adapting to window focus
- Settings persistence and first-launch flow
- Comprehensive test coverage (49 tests) with Jest
- Full ESLint compliance with proper TypeScript types

### ✅ Phase 1.1: Enhanced User Experience & Security (COMPLETED)

After completing the core desktop application, additional enhancements were implemented based on user feedback and security best practices:

**Recent Enhancements Completed:**

1. **🔐 Biometric Authentication System**

   - ✅ Touch ID support for macOS hosts file modifications
   - ✅ Intelligent fallback to password authentication
   - ✅ Real-time Touch ID availability detection with user guidance
   - ✅ Replaced unmaintained electron-sudo with modern sudo-prompt
   - ✅ Cross-platform privilege detection using native-is-elevated

2. **🪟 Multi-Window Architecture**

   - ✅ Dedicated editing windows for each website project
   - ✅ Context-aware menu system that adapts to focused window
   - ✅ Window state management preventing duplicate windows
   - ✅ Seamless website creation and editing workflow
   - ✅ Independent WebContentsView for each website window

3. **⚡ Enhanced Website Management**

   - ✅ Real-time website name validation with user feedback
   - ✅ In-place website renaming with validation
   - ✅ Context menu-based website operations (rename/delete)
   - ✅ Improved "New Website" button placement and functionality
   - ✅ Website selection window filtering (excludes already-open websites)

4. **🧪 Testing & Code Quality Improvements**
   - ✅ Comprehensive test suite expansion (49 tests total)
   - ✅ DNS/hosts manager testing with Touch ID mocking
   - ✅ IPC handlers testing for website management operations
   - ✅ Architecture testing to ensure modular design integrity
   - ✅ Complete ESLint compliance without disable comments

**Impact & Benefits:**

- **Security**: Enhanced with biometric authentication, eliminating reliance on unmaintained packages
- **User Experience**: Streamlined multi-website workflow with dedicated windows
- **Developer Experience**: Comprehensive testing and linting ensure maintainable codebase
- **Cross-Platform Readiness**: Modern authentication stack supports future Windows/Linux expansion

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
7. **✅ sudo-prompt over electron-sudo**: Modern, maintained authentication with Touch ID support
8. **✅ Multi-Window Architecture**: Dedicated windows improve workflow over single-window approach
9. **✅ Context-Aware Menus**: Dynamic menu system adapts to user focus
10. **✅ Comprehensive Testing Strategy**: 49 tests ensure reliability and maintainability

### Platform Readiness Assessment

- **macOS**: ✅ Production ready with full feature set
- **Windows**: 🟡 Core architecture compatible, certificate management needs adaptation
- **Linux**: 🟡 Core architecture compatible, hosts management may need sudo handling

### Success Metrics Achieved

#### Phase 1 Core Application

- **Functionality**: 100% of Phase 1 objectives completed
- **Security**: Zero admin privileges required, all operations sandboxed
- **User Experience**: First launch success rate improved with guided setup
- **Code Quality**: 65%+ test coverage, comprehensive documentation
- **Architecture**: Fully modular design ready for Phase 2 expansion

#### Phase 1.1 Enhanced Experience

- **Security**: 100% modern authentication stack with Touch ID support
- **User Experience**: Multi-window workflow significantly improves usability
- **Code Quality**: 49 comprehensive tests, 100% ESLint compliance
- **Cross-Platform Readiness**: Authentication system prepared for Windows/Linux
- **Developer Experience**: Complete TypeScript types, no linting disable comments

#### Overall Project Health

- **Test Coverage**: 49 tests across all major components
- **Documentation**: Complete architecture and technical documentation
- **Code Quality**: Zero linting errors, comprehensive TypeScript typing
- **Security**: Modern privilege escalation, biometric authentication
- **User Workflow**: Streamlined multi-website editing experience
