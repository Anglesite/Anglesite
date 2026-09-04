// swift-tools-version: 5.10
import PackageDescription
import Foundation

// The macOS app target itself is owned by Anglesite.xcodeproj (generated from
// project.yml via XcodeGen). This package exposes the supporting libraries
// that the app target links against, and drives CI via `swift test`.

// Step 1 of the Swift 6 migration: surface every data-race / isolation issue
// as a warning under Swift 5 mode. Once the tree is clean, flip these targets
// to the Swift 6 language mode (errors) by bumping swift-tools-version.
let strictConcurrency: [SwiftSetting] = [
    .enableUpcomingFeature("StrictConcurrency")
]

// Anywhere runtime (#1208): stasel/WebRTC vends a real dynamic .xcframework (unlike the
// source packages above), and SwiftPM's build system places its resolved WebRTC.framework
// directly in .build/<config>/Products/<config>/ — a *sibling* of a flat executable product,
// but three directories above an .xctest bundle's actual Mach-O (…/Foo.xctest/Contents/MacOS/Foo).
// A flat executable's default @loader_path rpath already reaches that directory, so
// anglesite-p2p-demo needs no extra help; an .xctest bundle's rpaths (@loader_path,
// @loader_path/../Frameworks, and an empty PackageFrameworks/) never do, so dyld fails to
// find @rpath/WebRTC.framework/WebRTC at test-run time without this. Adding the matching
// relative rpath here keeps the fix in Package.swift (portable across machines/CI) rather
// than a manual symlink into the gitignored .build directory.
let webRTCTestRPath: [LinkerSetting] = [
    .unsafeFlags(
        ["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../.."],
        .when(platforms: [.macOS])
    )
]

// AnglesiteContainer imports apple/containerization — a Swift 6.2, macOS-15+ package that pulls in
// the native NIO/gRPC/protobuf graph and only links on Apple-Silicon machines with the
// virtualization entitlement. `swift build` / `swift test` compile ALL of a package's products, so
// an *unconditional* AnglesiteContainer product would force CI's macos-15 runner to compile that
// whole graph (slow, and it can't run there anyway). The target/product/dependency are therefore
// included BY DEFAULT — so the Xcode app build, which evaluates this manifest without being able to
// inject env, gets the product to link — and dropped only when ANGLESITE_SKIP_CONTAINER=1, which
// CI sets at the workflow level. The virtualization entitlement, not this flag, gates the runtime
// at launch (see the #69 design §3 / §2.6).
#if canImport(Darwin)
let includeContainer = ProcessInfo.processInfo.environment["ANGLESITE_SKIP_CONTAINER"] != "1"
#else
// Apple Containerization is the macOS substrate; off-Darwin platforms get their own
// SiteRuntime implementations (cross-platform port design §7), so the container target —
// and its apple/containerization dependency — never enter the manifest there.
let includeContainer = false
#endif

// AnglesiteIntentsTests is conditionally included only on Swift 6.4+ (Xcode 27).
// The test binary loads `AnglesiteIntents` whose AppIntent metadata references
// `AppIntent.supportedModes` — a macOS 26+ symbol not present on the macOS 15
// runtime of GH's `macos-15` runner (which currently caps at Xcode 26.3).
// Locally on Xcode 27 the tests build + run normally; on the older toolchain
// we drop them so `swift test` still passes. Tracking removal in #128.
// SwiftGit2 (Anglesite's patched fork — see #640) is Darwin-only: it has no Linux platform
// entry, and the App Sandbox problem it solves doesn't exist off-macOS in the first place.
// GitInitRunner/NativeContentOperations keep the plain subprocess-git path as their
// #if !canImport(Darwin) branch, which is correct there, not just a fallback.
var anglesiteCoreDependencies: [Target.Dependency] = ["AnglesiteSiteModel"]
#if canImport(Darwin)
anglesiteCoreDependencies.append(.product(name: "SwiftGit2", package: "SwiftGit2"))
#endif

// RepoRelocatorTests (#877) verifies migrated gitfiles resolve via libgit2 directly
// (Repository.at), matching the InProcessGitTests cross-check style — so the test target
// needs the same Darwin-only SwiftGit2 dependency as AnglesiteCore itself.
var anglesiteCoreTestsDependencies: [Target.Dependency] = ["AnglesiteCore", "AnglesiteSiteModel", "AnglesiteTestSupport"]
#if canImport(Darwin)
anglesiteCoreTestsDependencies.append(.product(name: "SwiftGit2", package: "SwiftGit2"))
#endif

var packageTargets: [Target] = [
    .target(
        name: "AnglesiteSiteModel",
        path: "Sources/AnglesiteSiteModel",
        swiftSettings: strictConcurrency
    ),
    .target(
        name: "AnglesiteQuickLookSupport",
        dependencies: ["AnglesiteSiteModel"],
        path: "Sources/AnglesiteQuickLookSupport",
        swiftSettings: strictConcurrency
    ),
    .target(
        name: "AnglesiteCore",
        dependencies: anglesiteCoreDependencies,
        path: "Sources/AnglesiteCore",
        swiftSettings: strictConcurrency
    ),
    // Webview-agnostic message schema + overlay-bundle lookup (cross-platform port design §6
    // "AnglesiteBridgeCore split") — no WebKit import, so it's portable off-Darwin. Each
    // platform's webview adapter (AnglesiteBridge/WKWebView today; WebKitGTK/WebView2 later)
    // wraps this in its own script-injection/message-handler API.
    .target(
        name: "AnglesiteBridgeCore",
        dependencies: ["AnglesiteCore"],
        path: "Sources/AnglesiteBridgeCore",
        swiftSettings: strictConcurrency
    ),
    .target(
        name: "AnglesiteBridge",
        dependencies: ["AnglesiteCore", "AnglesiteBridgeCore"],
        path: "Sources/AnglesiteBridge",
        swiftSettings: strictConcurrency
    ),
    .target(
        name: "AnglesiteIOS",
        dependencies: ["AnglesiteSiteModel", "AnglesiteCore"],
        path: "Sources/AnglesiteIOS",
        swiftSettings: strictConcurrency
    ),
    .target(
        name: "AnglesiteIntents",
        // `AnglesiteIOS` is unconditional despite the name: `UbiquityContainerResolving`,
        // `UbiquitousPackageDiscovering`, and `NSMetadataQueryPackageDiscovery` are all
        // platform-neutral and already build and test on the macOS host (see the unconditional
        // `AnglesiteIOSTests` target below). Keeping the dependency gated to `.iOS` would force
        // `SiteEntityUbiquityDiscovery`'s orchestration behind an `#if os(iOS)` gate that
        // `swift test` can never reach (#1394).
        dependencies: ["AnglesiteCore", "AnglesiteIOS"],
        path: "Sources/AnglesiteIntents",
        swiftSettings: strictConcurrency
    ),
    .executableTarget(
        name: "AnglesiteLANHost",
        dependencies: ["AnglesiteCore"],
        path: "Sources/AnglesiteLANHost",
        swiftSettings: strictConcurrency
    ),
    // Test-only support shared across the test targets (e.g. the e2e prerequisite probes used by
    // both AnglesiteCoreTests and AnglesiteBridgeTests). Not exposed as a `.library` product, so
    // the app/xcodeproj never links it — only `swift test` builds it.
    .target(
        name: "AnglesiteTestSupport",
        dependencies: ["AnglesiteCore"],
        path: "Tests/AnglesiteTestSupport",
        swiftSettings: strictConcurrency
    ),
    .testTarget(
        name: "AnglesiteSiteModelTests",
        dependencies: ["AnglesiteSiteModel"],
        path: "Tests/AnglesiteSiteModelTests",
        swiftSettings: strictConcurrency
    ),
    .testTarget(
        name: "AnglesiteQuickLookSupportTests",
        dependencies: ["AnglesiteQuickLookSupport"],
        path: "Tests/AnglesiteQuickLookSupportTests",
        swiftSettings: strictConcurrency
    ),
    .testTarget(
        name: "AnglesiteCoreTests",
        dependencies: anglesiteCoreTestsDependencies,
        path: "Tests/AnglesiteCoreTests",
        // Tests/AnglesiteCoreTests/Fixtures/SiteImport/wp-site/ holds the ImportTransform golden
        // fixture (#1615 Task 13): a hand-authored ImportSnapshot plus the exact Source/ tree it
        // should produce. `.copy` (not `.process`) preserves the fixture's own directory layout
        // and byte-for-byte file contents in the test bundle, matching the convention other
        // targets in this file use for their own `Fixtures/` (see AnglesiteBridgeCoreTests below).
        resources: [.copy("Fixtures")],
        swiftSettings: strictConcurrency
    ),
    // Glibc-safe subset of what used to live in AnglesiteCoreTests (#1284): rather than
    // purity-sweep the whole ~300-file AnglesiteCoreTests target (most of it touches Darwin-only
    // surface — Keychain, NSFileCoordinator, AppleScript, the Darwin-only SwiftGit2 dependency,
    // etc.), the two PodmanContainerControl test files — already #if canImport(Glibc)-gated, and
    // depending on nothing but AnglesiteCore/Testing/Foundation — get their own small target so
    // they actually build and run on the Linux CI leg instead of silently compiling to nothing
    // everywhere. Depends only on AnglesiteCore, matching those files' actual imports.
    .testTarget(
        name: "AnglesiteCorePortableTests",
        dependencies: ["AnglesiteCore"],
        path: "Tests/AnglesiteCorePortableTests",
        swiftSettings: strictConcurrency
    ),
    .testTarget(
        name: "AnglesiteBridgeCoreTests",
        dependencies: ["AnglesiteBridgeCore", "AnglesiteCore"],
        path: "Tests/AnglesiteBridgeCoreTests",
        // AnglesiteWysiwygEngineBundleTests exercises the "resource absent" path (no engine.js
        // under wysiwyg-engine/ in the test bundle), but still needs SwiftPM to synthesize
        // `Bundle.module` for this target — that accessor is only generated when the target
        // has at least one real declared resource, so Fixtures/placeholder.txt exists purely
        // to trigger it (Tests/AnglesiteBridgeCoreTests/Fixtures/placeholder.txt).
        resources: [.copy("Fixtures")],
        swiftSettings: strictConcurrency
    ),
    .testTarget(
        name: "AnglesiteBridgeTests",
        dependencies: ["AnglesiteBridge", "AnglesiteTestSupport"],
        path: "Tests/AnglesiteBridgeTests",
        swiftSettings: strictConcurrency
    ),
    .testTarget(
        name: "AnglesiteIOSTests",
        dependencies: ["AnglesiteIOS", "AnglesiteSiteModel", "AnglesiteCore", "AnglesiteTestSupport"],
        path: "Tests/AnglesiteIOSTests",
        swiftSettings: strictConcurrency
    )
]

if includeContainer {
    packageTargets.append(
        .target(
            name: "AnglesiteContainer",
            dependencies: [
                "AnglesiteCore",
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization")
            ],
            path: "Sources/AnglesiteContainer",
            // `swift-tools-version: 5.10` silently drops `.copy()` resources whose path
            // escapes the target directory (no warning, no error — the resource bundle
            // just never gets the content). `Resources/container-{image,kernel,initfs}/`
            // are symlinked in-target here so the copy stays within
            // Sources/AnglesiteContainer while the vendored artifacts still live at the
            // top-level Resources/ alongside the rest of the app's bundled resources.
            resources: [
                .copy("Resources/container-image"),
                .copy("Resources/container-kernel"),
                .copy("Resources/container-initfs")
            ],
            swiftSettings: strictConcurrency
        )
    )
    // Standalone, individually-codesignable CLI so the live vsock/boot gate can run entitled
    // with `com.apple.security.virtualization` (see Resources/container-probe.entitlements and
    // scripts/run-container-probe.sh) — `swift test`'s own runner (swiftpm-testing-helper) can
    // never carry that entitlement. Included under the same `includeContainer` conditional as
    // AnglesiteContainer itself so CI (ANGLESITE_SKIP_CONTAINER=1) never sees it.
    packageTargets.append(
        .executableTarget(
            name: "AnglesiteContainerProbe",
            dependencies: [
                "AnglesiteContainer",
                "AnglesiteCore",
                .product(name: "Containerization", package: "containerization")
            ],
            path: "Sources/AnglesiteContainerProbe",
            swiftSettings: strictConcurrency
        )
    )
    // The actual Anywhere-runtime helper CLI (#1208 P1, Task 7): links AnglesiteContainer
    // directly (RemoteContainerSession -> ContainerizationControl), so — like
    // AnglesiteContainerProbe above — it lives inside `includeContainer` rather than the
    // unconditional `#if canImport(Darwin)` block below that defines its AnglesiteRemote/
    // AnglesiteP2P dependencies (those two have no AnglesiteContainer dependency of their own,
    // so they stay available even under ANGLESITE_SKIP_CONTAINER=1; this target can't).
    // Exposed as an SPM executableTarget — not just the Xcode `AnglesiteRemote` app target in
    // project.yml — so `swift build --product anglesite-remote-helper` produces a real binary
    // Task 8's HelperContainerE2ETests can spawn as a second process next to the test binary,
    // matching how P0's `TwoProcessE2ETests` spawns `anglesite-p2p-demo` the same way. No
    // explicit product entry needed below (mirrors anglesite-p2p-demo): SwiftPM synthesizes an
    // implicit product for every executable target.
    packageTargets.append(
        .executableTarget(
            name: "anglesite-remote-helper",
            dependencies: ["AnglesiteRemote", "AnglesiteCore", "AnglesiteContainer", "AnglesiteP2P"],
            path: "Sources/anglesite-remote-helper",
            swiftSettings: strictConcurrency
        )
    )
}

// canImport(Darwin) joins the compiler gate: these targets depend on AnglesiteBridge /
// AnglesiteIntents (WKWebView / AppIntents), so a future Swift 6.4 Linux toolchain must
// not pull them in.
#if compiler(>=6.4) && canImport(Darwin)
packageTargets.append(
    .target(
        name: "AnglesiteAppCore",
        dependencies: [
            "AnglesiteCore", "AnglesiteBridge", "AnglesiteIntents",
            .product(name: "STTextView", package: "STTextView"),
            // Module name is `STPluginNeon` (the target); the product name the dependency
            // resolver matches on is the package's own product name below.
            .product(name: "STTextView-Plugin-Neon", package: "STTextView-Plugin-Neon"),
            .product(name: "MarkdownEngine", package: "swift-markdown-engine"),
        ],
        path: "Sources/AnglesiteApp",
        exclude: ["AnglesiteApp.swift", "LiveSiteRuntimeFactory.swift"],
        swiftSettings: strictConcurrency + [.define("ANGLESITE_MAS")]
    )
)
packageTargets.append(
    .testTarget(
        name: "AnglesiteAppTests",
        dependencies: ["AnglesiteAppCore", "AnglesiteTestSupport"],
        path: "Tests/AnglesiteAppTests",
        swiftSettings: strictConcurrency
    )
)
packageTargets.append(
    .testTarget(
        name: "AnglesiteIntentsTests",
        // `AnglesiteIOS` for the `UbiquitousPackageDiscovering` fakes `SiteEntityUbiquityDiscovery`
        // is tested against; see the note on `AnglesiteIntents`' own dependency on it.
        // `AnglesiteTestSupport` for the shared `FakeUbiquityContainerResolver`.
        dependencies: ["AnglesiteIntents", "AnglesiteCore", "AnglesiteSiteModel", "AnglesiteIOS", "AnglesiteTestSupport"],
        path: "Tests/AnglesiteIntentsTests",
        swiftSettings: strictConcurrency
    )
)
#endif

// AnglesiteContainerLocalTests depends on AnglesiteContainer, which pulls in the native
// apple/containerization dependency and only links on Apple-Silicon dev machines with the
// virtualization entitlement. A bare `swift test` (CI) must NEVER compile it — so, mirroring
// the `#if compiler(>=6.4)` conditional-append above, the target is added only when
// ANGLESITE_CONTAINER_TESTS=1 is set in the build environment. Every test inside it also guards
// on ANGLESITE_CONTAINER_E2E at runtime. Run locally with:
//   ANGLESITE_CONTAINER_TESTS=1 ANGLESITE_CONTAINER_E2E=1 swift test --filter ContainerizationControlTests
if includeContainer && ProcessInfo.processInfo.environment["ANGLESITE_CONTAINER_TESTS"] == "1" {
    packageTargets.append(
        .testTarget(
            name: "AnglesiteContainerLocalTests",
            dependencies: [
                "AnglesiteContainer",
                "AnglesiteCore",
                "AnglesiteTestSupport",
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization")
            ],
            path: "Tests/AnglesiteContainerLocalTests",
            swiftSettings: strictConcurrency
        )
    )
}

// Anywhere runtime P0 (#1208): P2P transport core built on stasel/WebRTC's
// prebuilt libwebrtc xcframework (Darwin-only binary), so this target set
// only exists on Darwin — the dependency never enters the Linux graph.
#if canImport(Darwin)
packageTargets.append(contentsOf: [
    .target(
        name: "AnglesiteP2P",
        dependencies: [
            "AnglesiteCore",
            .product(name: "WebRTC", package: "WebRTC"),
        ],
        path: "Sources/AnglesiteP2P",
        swiftSettings: strictConcurrency
    ),
    .executableTarget(
        name: "anglesite-p2p-demo",
        dependencies: ["AnglesiteP2P"],
        path: "Sources/anglesite-p2p-demo",
        swiftSettings: strictConcurrency
    ),
    .testTarget(
        name: "AnglesiteP2PTests",
        dependencies: ["AnglesiteP2P", "AnglesiteTestSupport"],
        path: "Tests/AnglesiteP2PTests",
        swiftSettings: strictConcurrency,
        linkerSettings: webRTCTestRPath
    ),
    // Anywhere runtime P1 (#1208): the Mac helper's implementation library —
    // LoginItemRegistering today, RemoteSessionRegistry/RemoteContainerSession/etc. added by
    // later tasks in this plan. Darwin-only, matching AnglesiteP2P above: it wraps
    // ServiceManagement (macOS-only) and later tasks wire it to AnglesiteP2P (also Darwin-only).
    // Unlike AnglesiteAppCore (a test-only mirror of the app target's own inlined sources), this
    // one IS exposed as a real package product (see packageProducts below): the Xcode
    // AnglesiteRemote app target's own module is named "Anglesite_Remote" (mangled from its
    // PRODUCT_NAME, "Anglesite Remote") — a different module from "AnglesiteRemote" — so
    // Sources/anglesite-remote-helper/main.swift's `import AnglesiteRemote` needs this to be a
    // genuine linked dependency, not inlined sources of the same target.
    .target(
        name: "AnglesiteRemote",
        // AnglesiteCore is added explicitly (not just relied on transitively through
        // AnglesiteP2P) because Task 5's RemoteContainerSession consumes
        // LocalContainerControl/LocalContainerSession directly — see
        // Sources/AnglesiteCore/LocalContainerControl.swift.
        dependencies: ["AnglesiteP2P", "AnglesiteCore"],
        path: "Sources/AnglesiteRemote",
        swiftSettings: strictConcurrency
    ),
    .testTarget(
        name: "AnglesiteRemoteTests",
        dependencies: ["AnglesiteRemote", "AnglesiteCore", "AnglesiteTestSupport"],
        path: "Tests/AnglesiteRemoteTests",
        swiftSettings: strictConcurrency,
        linkerSettings: webRTCTestRPath
    ),
])
#endif

var packageProducts: [Product] = [
    .library(name: "AnglesiteSiteModel", targets: ["AnglesiteSiteModel"]),
    .library(name: "AnglesiteQuickLookSupport", targets: ["AnglesiteQuickLookSupport"]),
    .library(name: "AnglesiteCore", targets: ["AnglesiteCore"]),
    .library(name: "AnglesiteBridgeCore", targets: ["AnglesiteBridgeCore"]),
    .library(name: "AnglesiteBridge", targets: ["AnglesiteBridge"]),
    .library(name: "AnglesiteIOS", targets: ["AnglesiteIOS"]),
    .library(name: "AnglesiteIntents", targets: ["AnglesiteIntents"]),
    .executable(name: "anglesite-lan-host", targets: ["AnglesiteLANHost"])
]

// AnglesiteP2P and AnglesiteRemote both need real package products (not just internal targets):
// project.yml's new AnglesiteRemote app target (#1208 P1) references them via
// `package: Anglesite, product: AnglesiteP2P` / `product: AnglesiteRemote`, the same mechanism
// the Anglesite app target uses for AnglesiteCore/AnglesiteBridge/etc. Darwin-gated, matching
// both targets themselves above.
#if canImport(Darwin)
packageProducts.append(.library(name: "AnglesiteP2P", targets: ["AnglesiteP2P"]))
packageProducts.append(.library(name: "AnglesiteRemote", targets: ["AnglesiteRemote"]))
#endif

var packageDependencies: [Package.Dependency] = []

// Apple's official DocC generation plugin (#1041) — build-time only, never linked into the
// shipped app. Pinned to tag 1.5.0's commit, matching the revision-pin policy below (SwiftGit2 /
// STTextView): a floating `from:` requirement previously shipped an unreviewed breaking change
// (#774/#781/#783), so every dependency here is bumped deliberately.
packageDependencies.append(
    .package(url: "https://github.com/swiftlang/swift-docc-plugin.git", revision: "647c708be89f834fa6a6d4945442793a77ddf5b6")
)

#if canImport(Darwin)
// Anglesite's patched fork of mbernson/SwiftGit2 — see #640. Pinned
// to a commit rather than a tag or branch: SwiftGit2 upstream has no tagged SPM release yet, and
// pinning to anglesite/main's tip would silently pick up unreviewed future commits. Bump
// deliberately.
//
// Fork-tracking plan (#1804): `anglesite/main` carries 8 substantive commits beyond upstream's
// `develop` — the unborn-HEAD commit fix, defaultSignature(), remove/headHasEntry/
// restorePathFromHEAD (delete+undo), push/addAll/aheadBehind/addRemote (backup/publish),
// sandboxed remote/credential/error hardening, the #994 GIT_THREADS threading fix, and git-bundle
// read support (#988) — none offered upstream yet, though mbernson/SwiftGit2 is actively
// maintained (pushed as recently as 2026-08), not dead. libgit2 itself is a vendored submodule
// inside the fork, pinned at v1.9.4; nothing automated watches it for security releases —
// Dependabot's swift-ecosystem entry only sees this revision pin, not the submodule two hops
// down — so a libgit2 CVE reaches this app only via a manual rebase by whoever's doing dependency
// maintenance. Drop the fork once upstream tags an SPM release (blocked on its own PR #1) that
// carries equivalents of at least the unborn-HEAD and GIT_THREADS fixes — the two that are
// correctness/safety fixes rather than added convenience API. See #1804 for the full
// commit-by-commit accounting.
packageDependencies.append(
    .package(url: "https://github.com/Anglesite/SwiftGit2.git", revision: "446d4777ae4413c2faaa88425693ff29981e4b07")
)

// Anywhere runtime (#1208): prebuilt libwebrtc for the P2P transport core.
// Darwin-only binary xcframework — the target set below only includes
// AnglesiteP2P on Darwin, so the dependency never enters the Linux graph.
// Pinned by revision, matching the SwiftGit2/STTextView policy above (a mutable tag like
// `exact: "150.0.0"` can be re-pointed upstream without review): this is the commit release tag
// 150.0.0 resolves to.
packageDependencies.append(
    .package(url: "https://github.com/stasel/WebRTC.git", revision: "6ed87f05368632f71dc95c89c14c051561710925")
)

// Component Editor slice 4 (spec §7, §4.3): STTextView-backed code panes ("Props & Data",
// "Behavior") with tree-sitter syntax highlighting.
//   - STTextView is the TextKit 2 code-editing view itself (AppKit here — AnglesiteAppCore is
//     already Darwin/macOS-only).
//   - STTextView-Plugin-Neon wires Neon + SwiftTreeSitter highlighting into an STTextView via
//     its `NeonPlugin(theme:language:)`, bundling its own vendored tree-sitter grammars/queries
//     (TreeSitterResource, including CSS/JavaScript/TypeScript) — so these two packages cover
//     the whole highlighting stack the spec calls for, with no separate grammar packages
//     to add.
// Both AppKit-only, so gated the same as SwiftGit2 above.
// Pinned to a commit, not `from:` — `Package.resolved` is committed, but that doesn't protect a
// `from:` requirement: any other dependency change forces a re-resolve, and a floating `from:`
// here let one silently ship an API change (`text` became `String?`) that broke #774 (see #781,
// #783).
// Matches the SwiftGit2/STTextView-Plugin-Neon policy below: deliberate bumps only. This is tag
// 2.3.10's commit.
packageDependencies.append(
    .package(url: "https://github.com/krzyzanowskim/STTextView", revision: "8569251785daf1f0310eaa9235d1254264f0d249")
)
// Pinned to a commit, not `from:` — STTextView-Plugin-Neon's own manifest depends on Neon by
// `revision:` (Neon has no tagged SPM releases), and SwiftPM refuses to resolve a stable-version
// (`from:`) requirement on a package that itself depends on an unstable-version package. Pinning
// by revision here (rather than tracking `branch: "main"`) matches the SwiftGit2 policy above:
// deliberate bumps only, no silently picking up unreviewed future commits. This is tag 0.8.1's
// commit.
packageDependencies.append(
    .package(url: "https://github.com/krzyzanowskim/STTextView-Plugin-Neon", revision: "5a30db4ce7908a5414e7b499e2379bdc49991cd1")
)
// Markdown editor substrate (#797; survey #796 — see the spec addendum in
// docs/superpowers/specs/2026-07-17-blog-markdown-editor-publishing-design.md). Anglesite's
// fork of nodes-app/swift-markdown-engine v0.10.0 plus two patches (#1805):
//   - ff54708b: automatic quote substitution configurable (SpellCheckingPolicy.
//     automaticQuoteSubstitution) — smart quotes corrupt Markdown sources. Upstreamed as
//     nodes-app/swift-markdown-engine#174 (open, unreviewed as of 2026-09-03).
//   - badbaa4b: honor autoClosePairsEnabled for the `[`/`[[` auto-close paths in
//     MarkdownLists, so an embedder that disables auto-close (as this one does, for plain
//     Markdown source editing) doesn't get bracket pairs inserted underneath it. Upstreamed
//     as nodes-app/swift-markdown-engine#179 (open, unreviewed as of 2026-09-04).
// Drop condition: once both land in a tagged upstream release, switch this to `from:` that
// release (or the next deliberate bump per the policy below) and drop the fork.
// Rebase policy: matching SwiftGit2/STTextView-Plugin-Neon — deliberate bumps only, not a
// tracking branch. Upstream has moved to 0.11.0/0.12.0 since this fork's 0.10.0 base; nothing
// in that range has been surveyed for relevance, so treat a future bump as its own review, not
// a rubber-stamp fast-forward. Only the zero-dependency core `MarkdownEngine` product is linked
// (no MarkdownEngineCodeBlocks/MarkdownEngineLatex — LaTeX and highlighted fences are out of
// scope for v1, §A.2). Pinned by revision, matching the SwiftGit2/STTextView policy above:
// deliberate bumps only (upstream is pre-1.0 and its API moves).
packageDependencies.append(
    .package(url: "https://github.com/Anglesite/swift-markdown-engine", revision: "badbaa4b9816daf3baa82de625c2551c4e0b4d81")
)
#endif

// Keep the AnglesiteContainer product and its native dependency together with the target above:
// excluded as one unit under ANGLESITE_SKIP_CONTAINER=1 so the manifest never references a missing
// package/product, included by default otherwise.
if includeContainer {
    packageProducts.append(.library(name: "AnglesiteContainer", targets: ["AnglesiteContainer"]))
    packageProducts.append(.executable(name: "anglesite-container-probe", targets: ["AnglesiteContainerProbe"]))
    packageDependencies.append(
        .package(url: "https://github.com/apple/containerization.git", .upToNextMinor(from: "0.35.0"))
    )
}

// Cross-platform port, phase 1 "purity" (docs/superpowers/specs/2026-07-08-cross-platform-
// swift-port-design.md §10): off-Darwin, expose only the targets that actually compile
// there, so `swift build && swift test` stays green on the Linux CI leg and the compiler is
// the purity lint as seam PRs expand the portable set. AnglesiteSiteModel and
// AnglesiteQuickLookSupport (both pure Foundation) were first; AnglesiteCore joined once its
// Apple-only imports (FoundationModels, OSLog, Security, NSFileCoordinator, UndoManager,
// URLSession.bytes(for:), CFGetTypeID, security-scoped bookmarks, vsock proxies, …) all grew
// Platform/ seams or #if canImport gates (#566) — ANGLESITE_PORT_WIP no longer needs to opt it
// back in. AnglesiteCoreTests is not yet in this set: its test files aren't purity-swept.
// AnglesiteBridgeCore joined at phase 2 (#567): it's the webview-agnostic message-schema half
// of the former AnglesiteBridge (no WebKit import), split out so the message dispatch logic —
// and its tests — run on every platform; AnglesiteBridge itself (the WKWebView adapter) stays
// Darwin-only.
// AnglesiteCorePortableTests joined at phase 2 as well (#1284): the Glibc-gated
// PodmanContainerControl tests split out of AnglesiteCoreTests above so they actually run on
// this leg instead of just compiling out — AnglesiteCoreTests itself is still not in this set,
// since the rest of its ~300 files aren't purity-swept.
// Filtering by name here (rather than duplicating target definitions in per-platform
// lists) keeps the single source of truth above.
#if !canImport(Darwin)
let portableTargets: Set<String> = [
    "AnglesiteSiteModel", "AnglesiteSiteModelTests",
    "AnglesiteQuickLookSupport", "AnglesiteQuickLookSupportTests",
    "AnglesiteCore",
    "AnglesiteBridgeCore", "AnglesiteBridgeCoreTests",
    "AnglesiteCorePortableTests",
]
packageTargets.removeAll { !portableTargets.contains($0.name) }
// Every library product above is named after its single target, so the same name set
// filters products. (The container probe executable breaks that convention, but it is
// Darwin-only and already excluded via includeContainer.)
packageProducts.removeAll { !portableTargets.contains($0.name) }

// Cross-platform port phase 2 (#567): the Linux shell — GTK4/libadwaita via Adwaita for Swift,
// with a WebKitGTK preview (design §6). Opt-in via ANGLESITE_LINUX_SHELL=1 rather than
// default-on: building it needs GTK system headers (libadwaita ≥ 1.7 for adwaita-swift main's
// generated widgets, plus webkitgtk-6.0) that the Linux CI purity leg's swift:*-noble image
// doesn't carry (noble caps libadwaita at 1.5), so — mirroring ANGLESITE_CONTAINER_TESTS —
// the shell only enters the manifest when explicitly requested. Until a Flatpak-based CI lane
// exists (the packaging item on #567), a GTK-provisioned Linux box is the real verification,
// the same status PodmanContainerControl shipped with (#647).
if ProcessInfo.processInfo.environment["ANGLESITE_LINUX_SHELL"] == "1" {
    // Pinned to a commit, matching the SwiftGit2 policy above: adwaita-swift's only tag
    // (0.1.0) predates its current API, and tracking main would silently pick up unreviewed
    // commits. Bump deliberately. (Its own dependencies are branch-based, which SwiftPM
    // permits under a revision pin — but they can only float: SwiftPM rejects a root-level
    // revision pin of a dependency another package requires by branch ("required using two
    // different revision-based requirements"), so Meta and friends cannot be frozen from
    // here, and an upstream push to their main can break this target with no change in this
    // repo. Twice now: #1385 was Meta's main dropping WidgetData.stateManager out from under
    // every adwaita-swift revision, then restoring it a few commits later; #1760 was Meta's
    // main switching to the Swift 6 language mode (183233a — @MainActor on App, AnyView,
    // ViewBuilder, WidgetData, …), which turned every pre-Swift-6 adwaita-swift revision's
    // PreferencesDialog/Window into "main actor-isolated … in a synchronous nonisolated
    // context" errors until adwaita-swift followed with defaultIsolation(MainActor) an hour
    // later (df1b4f3). When the Flatpak lane fails inside .build/checkouts with no change
    // here, the fix is this pin: bump to the first adwaita-swift main commit that compiles
    // against Meta's current main. This pin needs Meta main ≥ 183233a (Swift 6 mode) and
    // tools ≥ 6.3 (adwaita-swift's manifest; Flathub's swift6//25.08 extension is 6.3.3).
    // The git.aparoksha.dev URL now redirects to codeberg.org/aparoksha; SwiftPM follows it
    // silently, and adwaita-swift's own manifest still names its siblings (meta, meta-sqlite,
    // levenshtein-transformations) by the aparoksha.dev URL, so this stays consistent with
    // it rather than being the one package resolved by a different identity.
    packageDependencies.append(
        .package(url: "https://git.aparoksha.dev/aparoksha/adwaita-swift", revision: "df1b4f3c432bfc284d7c42990c3688a0ccf62322")
    )
    packageTargets.append(
        .systemLibrary(name: "CWebKitGTK", path: "Sources/CWebKitGTK", pkgConfig: "webkitgtk-6.0")
    )
    packageTargets.append(
        .executableTarget(
            name: "AnglesiteLinux",
            dependencies: [
                "AnglesiteCore",
                "AnglesiteBridgeCore",
                "CWebKitGTK",
                .product(name: "Adwaita", package: "adwaita-swift")
            ],
            path: "Sources/AnglesiteLinux",
            swiftSettings: strictConcurrency
        )
    )
    packageProducts.append(.executable(name: "anglesite-linux", targets: ["AnglesiteLinux"]))
    // Depends on the AnglesiteLinux target itself (for @testable import), so it inherits the
    // same GTK-toolchain requirement and only enters the graph under this same
    // ANGLESITE_LINUX_SHELL=1 gate — but the tests it holds today (ShellModel.overlayCandidates,
    // a pure function with no GTK/Adwaita touch points) need none of that to actually run; the
    // gating is a build-graph consequence of testing the target, not a requirement of the tests
    // themselves.
    packageTargets.append(
        .testTarget(
            name: "AnglesiteLinuxTests",
            dependencies: ["AnglesiteLinux"],
            path: "Tests/AnglesiteLinuxTests",
            swiftSettings: strictConcurrency
        )
    )
}
#endif

let package = Package(
    name: "Anglesite",
    platforms: [
        .macOS("27.0"),
        .iOS("27.0")
    ],
    products: packageProducts,
    dependencies: packageDependencies,
    targets: packageTargets
)
