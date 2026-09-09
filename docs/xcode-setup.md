# Xcode Project Setup

The SwiftPM scaffold builds and tests via `swift build` / `swift test`. The
generated Xcode project owns the runnable macOS app target, including
`Info.plist`, entitlements, signing, and build phases for bundling the
container image, the WYSIWYG engine bundle (`Resources/wysiwyg-engine/`), and the
Help Book.

`Anglesite.xcodeproj` is generated from [`project.yml`](../project.yml) via
[XcodeGen](https://github.com/yonaskolb/XcodeGen). It is gitignored; edit
`project.yml`, not the generated project.

## Target

| Target | Bundle id | Distribution | Sandbox |
|---|---|---|---|
| `Anglesite` | `io.dwk.anglesite` | Mac App Store | App Sandbox |

`Anglesite` is the only app target. It sets `ANGLESITE_MAS`, links
`AnglesiteContainer`, and uses `Resources/Anglesite.entitlements`.

## One-Time Setup

1. Install XcodeGen if needed:

   ```sh
   brew install xcodegen
   ```

2. Generate the Xcode project:

   ```sh
   xcodegen generate
   ```

3. Open the project:

   ```sh
   open Anglesite.xcodeproj
   ```

## Debug Build

Debug builds are ad-hoc signed and need no Apple account:

```sh
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
```

## App Store Release

Release builds use `Apple Distribution` signing and require a paid Apple
Developer account and a standard Mac App Store provisioning profile for
`io.dwk.anglesite`. No entitlement approval is involved:
`com.apple.security.virtualization` is unrestricted (it even works on ad-hoc
Debug builds).

The release flow is documented in [release.md](release.md) and driven by:

```sh
TEAM_ID=YOUR_TEAM_ID \
PROVISIONING_PROFILE="Anglesite App Store" \
ASC_API_KEY_ID=XXXXXXXXXX \
ASC_API_ISSUER_ID=00000000-0000-0000-0000-000000000000 \
  scripts/release.sh --validate-only
```

## Xcode Cloud

For a build+test CI signal from Xcode Cloud (in addition to GitHub Actions), see
[xcode-cloud.md](xcode-cloud.md).
