# Anglesite Architecture

Anglesite is a local-first, Electron-based static site generator that combines Eleventy's powerful site generation with a native desktop application experience. This document describes the current architecture and design decisions.

## System Overview

```mermaid
graph TB
    subgraph "Electron Main Process"
        Main[main.ts]
        Store[Store<br/>Settings Management]
        Cert[Certificate Manager]
        DNS[DNS/Hosts Manager<br/>Touch ID Support]
        Server[Server Manager]
        IPC[IPC Handlers]
    end

    subgraph "Electron Renderer Process"
        UI[UI/Window Manager]
        MultiWin[Multi-Window Manager]
        Menu[Application Menu]
        Preview[WebContentsView<br/>Preview]
        Websites[Dedicated Website<br/>Windows]
    end

    subgraph "External Services"
        Eleventy[Eleventy Server<br/>Port 8081]
        HTTPS[HTTPS Proxy<br/>Port 8080]
        Hosts["/etc/hosts"]
        Keychain[System Keychain]
    end

    Main --> Store
    Main --> Cert
    Main --> DNS
    Main --> Server
    Main --> IPC

    IPC <--> UI
    IPC <--> MultiWin
    UI --> Preview
    UI --> Menu
    MultiWin --> Websites
    MultiWin --> Menu

    Server --> Eleventy
    Server --> HTTPS
    DNS --> Hosts
    Cert --> Keychain

    HTTPS --> Eleventy
    Preview --> HTTPS
```

## Directory Structure

```text
anglesite/
├── app/                        # Electron application source
│   ├── main.ts                 # Main process entry point
│   ├── preload.ts              # Preload script for renderer
│   ├── renderer.ts             # Renderer process code
│   ├── index.html              # Main window HTML
│   ├── styles.css              # Application styles
│   ├── store.ts                # Persistent settings storage
│   ├── certificates.ts         # CA and SSL certificate management
│   │
│   ├── dns/                    # DNS management
│   │   └── hosts-manager.ts    # /etc/hosts file management
│   │
│   ├── server/                 # Server components
│   │   ├── eleventy.ts         # Eleventy server management
│   │   ├── https-proxy.ts      # HTTPS proxy server
│   │   └── index.ts            # Server module exports
│   │
│   ├── ui/                     # User interface components
│   │   ├── window-manager.ts   # Window and WebContentsView
│   │   ├── multi-window-manager.ts # Multi-window management
│   │   ├── menu.ts             # Application menu
│   │   ├── first-launch.html   # First launch assistant
│   │   └── index.ts            # UI module exports
│   │
│   ├── ipc/                    # Inter-process communication
│   │   └── handlers.ts         # IPC message handlers
│   │
│   ├── utils/                  # Utility functions
│   │   └── website-manager.ts  # Website creation/management
│   │
│   └── eleventy/               # Eleventy configuration
│       ├── .eleventy.js        # Eleventy config
│       ├── includes/           # Layout templates
│       └── src/                # Default content
│
├── dist/                       # Compiled output
│   ├── app/                    # Compiled TypeScript
│   └── [site files]            # Built static site
│
├── docs/                       # Project documentation
├── test/                       # Test files
├── bin/                        # Legacy shell scripts
└── package.json                # Dependencies and scripts
```

## Core Components

### 1. Application Initialization Flow

```mermaid
sequenceDiagram
    participant User
    participant Main as Main Process
    participant Store as Settings Store
    participant FL as First Launch
    participant DNS as DNS Manager
    participant Server as Server Manager
    participant UI as UI Manager

    User->>Main: Launch App
    Main->>Store: Load Settings

    alt First Launch
        Main->>FL: Show Setup Assistant
        FL->>User: Choose HTTPS/HTTP
        User->>FL: Select Mode
        FL->>Store: Save Preference

        opt HTTPS Mode
            FL->>Main: Install CA Certificate
        end
    end

    Main->>DNS: Cleanup Hosts File
    DNS->>DNS: Remove Orphaned Entries

    Main->>Server: Start Eleventy
    Server->>Server: Start on Port 8081

    opt HTTPS Mode Enabled
        Server->>Server: Start HTTPS Proxy
        Server->>Server: Port 8080 -> 8081
    end

    Main->>UI: Create Main Window
    UI->>UI: Load Preview
```

### 2. Certificate Management

The certificate system uses the `mkcert` npm package to generate trusted SSL certificates:

```mermaid
graph LR
    subgraph "Certificate Authority"
        CA[Anglesite CA<br/>~/Library/Application Support/<br/>Anglesite/ca/]
        CAcrt[ca.crt]
        CAkey[ca.key]
        CA --> CAcrt
        CA --> CAkey
    end

    subgraph "Certificate Generation"
        Gen[generateCertificate]
        Cache[Certificate Cache]
        Gen --> Cache
    end

    subgraph "System Integration"
        Keychain[User Keychain]
        Trust[Trust Settings]
    end

    CAcrt --> Gen
    CAkey --> Gen
    Gen --> Keychain
    Keychain --> Trust
```

**Key Features:**

- Self-contained CA generation
- Certificate caching for performance
- User keychain installation (no admin required)
- Fallback to HTTP if certificate issues

### 3. DNS and Hosts Management with Biometric Authentication

```mermaid
stateDiagram-v2
    [*] --> CheckWebsites: App Launch
    CheckWebsites --> CheckTouchID: Detect Biometrics
    CheckTouchID --> ScanDirectories: List Website Folders
    ScanDirectories --> CompareHosts: Compare with /etc/hosts

    CompareHosts --> RemoveOrphans: Found Orphans
    CompareHosts --> AddMissing: Missing Entries
    CompareHosts --> NoChanges: All Synced

    RemoveOrphans --> RequestAuth: Need Elevation
    AddMissing --> RequestAuth: Need Elevation
    RequestAuth --> TouchIDAuth: Touch ID Available
    RequestAuth --> PasswordAuth: Touch ID Not Available
    TouchIDAuth --> UpdateHosts: Authenticated
    PasswordAuth --> UpdateHosts: Authenticated
    UpdateHosts --> [*]: Complete
    NoChanges --> [*]: Complete
```

**Enhanced Authentication System:**

- **Touch ID Support**: Native biometric authentication on supported macOS systems
- **Fallback Authentication**: Password prompt when Touch ID unavailable
- **Privilege Detection**: Uses `native-is-elevated` to check current permissions
- **Secure Elevation**: `sudo-prompt` integration for administrator access

**Automatic Management:**

- Scans `~/Library/Application Support/Anglesite/websites/`
- Maintains Anglesite section in `/etc/hosts`
- Removes orphaned .test domains
- Adds new website domains automatically
- Preserves system entries outside Anglesite section
- Single authentication prompt for batch operations

### 4. Multi-Window Architecture

```mermaid
graph TD
    subgraph "Window Management"
        Main[Main Help Window]
        Selection[Website Selection]
        WebWin1[Website Window 1]
        WebWin2[Website Window 2]
        WebWinN[Website Window N]
    end

    subgraph "Window Features"
        Preview[Preview WebContentsView]
        DevTools[Developer Tools]
        MenuBar[Dynamic Menu Bar]
    end

    Main --> Selection
    Selection --> WebWin1
    Selection --> WebWin2
    Selection --> WebWinN

    WebWin1 --> Preview
    WebWin2 --> Preview
    WebWinN --> Preview

    Main --> MenuBar
    WebWin1 --> MenuBar
    WebWin2 --> MenuBar
```

**Key Features:**

- **Dedicated Website Windows**: Each website opens in its own isolated window
- **Context-Aware Menus**: Menu bar adapts based on focused window type
- **Independent Preview**: Each website window has its own WebContentsView
- **Window State Management**: Tracks open websites and prevents duplicates
- **Seamless Editing Workflow**: Direct website creation and editing flow

### 5. Website Management

```mermaid
graph TD
    subgraph "Website Creation"
        NewSite[New Website Request]
        Validate[Validate Name]
        CreateDir[Create Directory]
        CreateFiles[Create index.md]
        AddDNS[Add to /etc/hosts]
        StartServer[Switch Server Context]
    end

    NewSite --> Validate
    Validate -->|Valid| CreateDir
    Validate -->|Invalid| Error[Show Error]
    CreateDir --> CreateFiles
    CreateFiles --> AddDNS
    AddDNS --> StartServer

    subgraph "Website Structure"
        WebDir[websites/sitename/]
        IndexMD[index.md]
        WebDir --> IndexMD
    end
```

### 5. Server Architecture

```mermaid
graph LR
    subgraph "Development Server Stack"
        Browser[Browser]
        HTTPS[HTTPS Proxy<br/>:8080]
        HTTP[Eleventy Server<br/>:8081]
        Files[Website Files]
    end

    Browser -->|https://site.test:8080| HTTPS
    HTTPS -->|Proxy to localhost| HTTP
    HTTP -->|Serve| Files

    Browser -->|http://localhost:8081| HTTP
```

**Dual Mode Support:**

- **HTTPS Mode**: Browser → HTTPS Proxy (:8080) → Eleventy (:8081)
- **HTTP Mode**: Browser → Eleventy (:8081) directly
- Hot reload via Eleventy's built-in WebSocket

## Data Flow

### IPC Communication

```mermaid
sequenceDiagram
    participant R as Renderer
    participant P as Preload
    participant M as Main Process
    participant H as IPC Handlers

    R->>P: UI Event
    P->>M: IPC Message
    M->>H: Route to Handler
    H->>H: Process Request
    H->>M: Return Result
    M->>P: IPC Reply
    P->>R: Update UI
```

**Key IPC Channels:**

- `new-website`: Create new website with validation
- `list-websites`: Get available websites (excluding open ones)
- `open-website`: Open website in dedicated window
- `validate-website-name`: Real-time name validation
- `rename-website`: Rename existing website
- `delete-website`: Delete website with confirmation
- `preview`: Show preview window
- `toggle-devtools`: Toggle developer tools
- `build`: Trigger site build
- `open-browser`: Open in external browser
- `show-website-context-menu`: Display right-click menu

## Security Architecture

### Certificate Trust Model

```mermaid
graph TD
    subgraph "Trust Hierarchy"
        RootCA[Anglesite Root CA]
        SiteCert[Site Certificate]
        Browser[Browser Trust]
    end

    RootCA -->|Signs| SiteCert
    RootCA -->|Installed in| Keychain[User Keychain]
    Keychain -->|Trusts| Browser
    Browser -->|Validates| SiteCert
```

### Permission Model

1. **File System Access**
   - Application data: `~/Library/Application Support/Anglesite/`
   - Website storage: Isolated in app data
   - No access to user documents without explicit action

2. **Network Security**
   - Local-only servers (127.0.0.1)
   - No external network access
   - HTTPS certificates for .test domains only

3. **System Integration**
   - Hosts file modification with biometric authentication (Touch ID)
   - Fallback to password authentication when biometrics unavailable
   - Certificate installation in user keychain
   - Privilege escalation using `sudo-prompt` (replaces electron-sudo)
   - No system-wide changes without explicit consent

## State Management

```mermaid
stateDiagram-v2
    [*] --> Uninitialized
    Uninitialized --> FirstLaunch: No Settings
    Uninitialized --> Loading: Has Settings

    FirstLaunch --> HTTPMode: User Selects HTTP
    FirstLaunch --> HTTPSMode: User Selects HTTPS

    Loading --> HTTPMode: Mode = HTTP
    Loading --> HTTPSMode: Mode = HTTPS

    HTTPMode --> Running: Server Started
    HTTPSMode --> InstallingCA: Install Certificate
    InstallingCA --> Running: Success
    InstallingCA --> HTTPMode: Failed

    Running --> Creating: New Website
    Creating --> Running: Complete
    Running --> Switching: Change Website
    Switching --> Running: Complete
```

## Performance Optimizations

1. **Certificate Caching**
   - In-memory cache for generated certificates
   - Avoids regenerating for same domains

2. **Lazy Loading**
   - WebContentsView created once, reused
   - Eleventy server persists between site switches

3. **Hosts File Management**
   - Batch operations for multiple domains
   - Single biometric/password prompt for all changes
   - Intelligent privilege checking with `native-is-elevated`
   - Touch ID detection and user guidance

4. **Multi-Window Optimization**
   - Window state tracking prevents duplicate windows
   - Context-aware menu updates
   - Efficient WebContentsView reuse

## Future Architecture Considerations

### Planned Improvements

1. **Plugin System**
   - Extensible Eleventy configurations
   - Custom build pipelines
   - Third-party integrations

2. **Multi-Site Management**
   - Concurrent site editing
   - Site templates and themes
   - Import/export functionality

3. **Deployment Integration**
   - Direct deploy to hosting services
   - Git integration
   - CI/CD pipeline support

### Scalability Considerations

- **Website Limit**: Currently unlimited (filesystem constrained)
- **Performance**: Handles 100+ websites efficiently
- **Memory Usage**: ~150MB baseline, scales with preview content
- **Certificate Management**: Cached, 365-day validity

## Technology Stack

### Core Dependencies

- **Electron**: Desktop application framework
- **Eleventy**: Static site generator engine
- **TypeScript**: Type-safe development
- **Jest**: Testing framework with comprehensive mocking

### Authentication & Security

- **sudo-prompt**: Secure privilege escalation (replaced electron-sudo)
- **native-is-elevated**: Cross-platform privilege detection
- **hostile**: Cross-platform hosts file management
- **mkcert**: SSL certificate generation

### UI & Window Management

- **WebContentsView**: Modern preview integration
- **BrowserWindow**: Multi-window architecture
- **IPC**: Secure inter-process communication

## Development Workflow

```mermaid
graph LR
    subgraph "Development"
        Code[TypeScript Source]
        Compile[tsc Compilation]
        JS[JavaScript Output]
    end

    subgraph "Testing"
        Jest[Jest Tests]
        Lint[ESLint]
        Format[Prettier]
    end

    subgraph "Build"
        Bundle[Electron Bundle]
        Static[Eleventy Build]
    end

    Code --> Compile
    Compile --> JS
    Code --> Jest
    Code --> Lint
    Code --> Format

    JS --> Bundle
    JS --> Static
```

## Conclusion

Anglesite's architecture prioritizes:

- **Simplicity**: Minimal configuration, works out of the box
- **Security**: Sandboxed, local-only, user-controlled
- **Performance**: Efficient resource usage, fast preview updates
- **Extensibility**: Modular design allows for future growth

The architecture successfully balances the power of Eleventy with the convenience of a desktop application, providing a seamless local development experience for static sites.
