# Anglesite 💎

Anglesite is a local-first, Electron-based static site generator that combines the power of [Eleventy](https://www.11ty.dev/) with an intuitive desktop application. It enables both technical and non-technical users to create, manage, and preview static websites locally with automatic HTTPS support and seamless .test domain management.

## Features

- **Native Desktop Application**: Built with Electron for a seamless local development experience
- **Automatic HTTPS Support**: Local SSL certificates with trusted CA installation
- **Smart DNS Management**: Automatic .test domain configuration via /etc/hosts
- **Live Preview**: Real-time preview with hot reload powered by Eleventy
- **Developer Tools**: Built-in DevTools for debugging and inspection
- **First Launch Assistant**: Guided setup for HTTPS/HTTP mode selection
- **Zero Configuration**: Works out of the box with sensible defaults

## Getting Started

### Prerequisites

- Node.js 18+ and npm
- macOS (primary support), Windows, or Linux

### Installation

1. Clone the repository:

   ```bash
   git clone https://github.com/anglesite/anglesite.git
   cd anglesite
   ```

2. Install dependencies:

   ```bash
   npm install
   ```

3. Build the application:

   ```bash
   npm run build
   ```

4. Start Anglesite:

   ```bash
   npm start
   ```

### First Launch

On first launch, Anglesite will present a setup assistant:

1. **Choose Development Mode**:

   - **HTTPS Mode** (Recommended): Secure local development with SSL certificates
   - **HTTP Mode**: Basic HTTP connections without certificate setup

2. **Certificate Installation** (HTTPS mode only):

   - Anglesite will install a local Certificate Authority in your user keychain
   - This enables trusted HTTPS connections for .test domains
   - No administrator privileges required

3. **Start Creating**: Once setup is complete, you can immediately create your first website

## Usage

### Creating a Website

1. Click **File → New Website** or use `Cmd+N`
2. Enter a name for your website (e.g., "portfolio")
3. Anglesite automatically:
   - Creates the website directory
   - Configures the domain (portfolio.test)
   - Updates /etc/hosts
   - Opens the preview

### Website Structure

Websites are stored in:

```text
~/Library/Application Support/Anglesite/websites/
└── your-site/
    └── index.md
```

Each website uses Markdown files that are automatically converted to HTML by Eleventy.

### Previewing Your Site

- **Local Preview**: Your site is available at `https://sitename.test:8080` (HTTPS mode) or `http://localhost:8081` (HTTP mode)
- **Live Reload**: Changes to your files automatically refresh the preview
- **DevTools**: Toggle developer tools with `Cmd+Option+I`
- **External Browser**: Open in your default browser with `Cmd+Shift+O`

### Building for Production

Click **Build** or use `Cmd+B` to generate the static HTML files. The built site will be placed in your website's directory.

## Development

### Project Structure

```text
app/                    # Electron application source
├── main.ts            # Main process entry point
├── certificates.ts    # SSL certificate management
├── dns/              # DNS and hosts file management
├── server/           # Eleventy and HTTPS proxy servers
├── ui/               # Window and UI components
├── ipc/              # Inter-process communication
└── utils/            # Website management utilities

dist/                  # Compiled output
docs/                  # Project documentation
test/                  # Test files
```

### Available Scripts

- `npm start` - Launch the application
- `npm run build` - Build Eleventy sites
- `npm test` - Run Jest tests
- `npm run lint` - Run ESLint
- `npm run format` - Format code with Prettier
- `npm run typecheck` - Run TypeScript type checking

### Architecture

Anglesite uses a multi-process architecture:

- **Main Process**: Manages application lifecycle, servers, and system integration
- **Renderer Process**: Handles UI and preview display
- **Eleventy Server**: Serves website content with hot reload
- **HTTPS Proxy**: Provides SSL termination for .test domains

For detailed architecture documentation, see [docs/architecture.md](docs/architecture.md).

## Security

- **Local Only**: All servers bind to 127.0.0.1 (localhost only)
- **User Keychain**: CA certificates installed in user keychain (no admin required)
- **Sandboxed**: Websites isolated in application data directory
- **No External Access**: No network requests or telemetry

## Troubleshooting

### Certificate Issues

If you encounter SSL certificate errors:

1. Open Keychain Access
2. Search for "Anglesite Development"
3. If found, delete it
4. Restart Anglesite to regenerate

### Hosts File Permissions

Updating /etc/hosts requires administrator privileges. You'll be prompted for your password when:

- Creating a new website
- Starting the application (for cleanup)

### Reset First Launch

To reset the first launch flow:

1. Quit Anglesite
2. Delete the settings file:

   ```bash
   rm ~/Library/Application\ Support/Anglesite/settings.json
   ```

3. Restart Anglesite

## Contributing

We welcome contributions! Please:

1. Fork the repository
2. Create a feature branch
3. Follow the existing code style
4. Add tests for new features
5. Ensure all tests pass
6. Submit a pull request

For more details, see [docs/requirements.md](docs/requirements.md).

## Roadmap

- [ ] Plugin system for Eleventy configurations
- [ ] Theme marketplace integration
- [ ] Git integration for version control
- [ ] Direct deployment to hosting services
- [ ] Multi-site concurrent editing
- [ ] Custom domain support beyond .test
- [ ] Windows and Linux certificate management

## License

Anglesite is licensed under the ISC License. See the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Built on [Eleventy](https://www.11ty.dev/) static site generator
- Uses [mkcert](https://github.com/FiloSottile/mkcert) for certificate generation
- Inspired by the need for accessible, local-first web development tools
