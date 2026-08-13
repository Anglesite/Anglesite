# Release Pipeline

Anglesite ships through the Mac App Store only.

The single app target is `Anglesite` with bundle id `io.dwk.anglesite`. It is
sandboxed, uses App Store signing, and gets updates from App Store Connect. There
is no direct-download update feed, GitHub Release artifact, or notarized zip path.

## One-Time Setup

1. **App Store Connect app record.** Create an app for bundle id
   `io.dwk.anglesite` in [App Store Connect](https://appstoreconnect.apple.com/).
   The build will not upload until the record exists.

2. **Certificates.** In the Apple Developer portal, create and install in your
   login keychain:
   - an **Apple Distribution** certificate, which signs the `.app`;
   - a **Mac Installer Distribution** certificate, which signs the outer `.pkg`.

   Also install the **Apple WWDR** intermediate from
   <https://www.apple.com/certificateauthority/>. `scripts/release.sh`
   preflights these and fails early if any are missing.

3. **Provisioning profile.** Create a **Mac App Store** provisioning profile for
   `io.dwk.anglesite` tied to the Apple Distribution cert, download it, and
   install it. Note its name; pass it as `PROVISIONING_PROFILE`.

4. **Virtualization entitlement — nothing to request.** The app entitlement file
   includes `com.apple.security.virtualization` for Apple Containerization. It is an
   unrestricted entitlement: it is not a portal capability, needs no Apple approval,
   and is honored under any signature (even ad-hoc Debug builds boot containers —
   verified 2026-07-07). A standard Mac App Store profile suffices; confirm upload
   validation accepts it with `scripts/release.sh --validate-only` (precedent: the
   sandboxed `try-containers/Containers` app ships it on the Mac App Store).

5. **App Store Connect API key.** In App Store Connect -> Users and Access ->
   Integrations -> App Store Connect API, create a key with the App Manager role.
   Put the `.p8` in `~/.appstoreconnect/private_keys/` or `~/.private_keys/`, and
   record the Key ID and Issuer ID.

## Per-Release Flow

Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml` if needed,
then run:

```sh
TEAM_ID=YOUR_TEAM_ID \
PROVISIONING_PROFILE="Anglesite App Store" \
ASC_API_KEY_ID=XXXXXXXXXX \
ASC_API_ISSUER_ID=00000000-0000-0000-0000-000000000000 \
  scripts/release.sh
```

The script:

1. runs `xcodegen generate`;
2. archives the `Anglesite` scheme;
3. verifies the archived app signature and Team ID;
4. exports, and unless `--validate-only` uploads, an App Store `.pkg` via
   `xcodebuild -exportArchive`.

Use `--validate-only` to archive/export/validate without uploading. Transporter
is still a valid manual fallback: drop the exported `.pkg` onto Transporter.app.

## TestFlight Beta Distribution

TestFlight builds go through the exact same pipeline as a full release --
`scripts/release.sh` archives, signs, and uploads to App Store Connect, and
that upload *is* the TestFlight build-upload path. There is no separate
"upload for beta" step. What's specific to TestFlight is App Store
Connect configuration (mostly manual) and setting the build's "What to
Test" notes (scripted).

### One-time setup (manual, in App Store Connect)

1. **TestFlight tab.** Nothing to create separately -- it appears
   automatically on the app record from step 1 of "One-Time Setup" above,
   once the first build is uploaded and finishes processing.
2. **Export compliance.** `Resources/Info.plist` declares
   `ITSAppUsesNonExemptEncryption=false` (accurate -- Anglesite only uses
   standard HTTPS/TLS via system frameworks, no custom cryptography). This
   skips App Store Connect's manual export-compliance prompt, which
   otherwise blocks a build from being distributed to any tester group
   until answered.
3. **Internal Testing group.** App Store Connect -> TestFlight -> Internal
   Testing -> create a group, add testers by Apple ID (they must already
   have a role on the App Store Connect team), then add a processed build
   to the group. No Beta App Review required -- builds are available to
   internal testers immediately.
4. **External Testing group -- when to open one.** Left as a deliberate
   judgment call, not automated here: open an External Testing group once
   internal testers have validated a build and you want feedback from
   people outside the Apple Developer team. The first build submitted to
   an external group needs Beta App Review (typically faster and lighter
   than full App Store review); most builds after that, without
   significant changes, don't need re-review.
5. **Virtualization entitlement.** Already confirmed in "One-Time Setup"
   step 4 above -- the same `scripts/release.sh --validate-only` check
   covers TestFlight builds, since they go through the identical export
   pipeline.

### Beta release flow

```sh
# 1. Archive, sign, and upload -- same as a full release.
TEAM_ID=YOUR_TEAM_ID \
PROVISIONING_PROFILE="Anglesite App Store" \
ASC_API_KEY_ID=XXXXXXXXXX \
ASC_API_ISSUER_ID=00000000-0000-0000-0000-000000000000 \
  scripts/release.sh

# 2. Wait until the build appears under TestFlight -> Builds in App Store
#    Connect, then run step 3 below (it polls while the build finishes
#    processing, but won't wait for the build to first appear).

# 3. Set the "What to Test" notes for testers.
ASC_API_KEY_ID=XXXXXXXXXX \
ASC_API_ISSUER_ID=00000000-0000-0000-0000-000000000000 \
  scripts/testflight-notes.sh --notes "Try the new site importer and report crashes."
```

Then add the build to a tester group (Internal or External) in App Store
Connect -- see "One-time setup" above.

See [#617](https://github.com/Anglesite/Anglesite/issues/617) for the
separate v1.0 App Store submission track, which shares this same
archive/export/upload pipeline but goes through full App Review instead
of TestFlight's Beta App Review.

## iOS App Store Lane (AnglesiteMobile)

`AnglesiteMobile` ships as its **own App Store product**, separate from the Mac
app — a distinct app record, provisioning, and TestFlight/App Review cycle. See
`docs/superpowers/specs/2026-08-12-ios-ipados-v2-design.md` §4 for the design
this section implements (epic #342, tracking issue #1434).

The target's bundle id is `io.dwk.anglesite.ios`, already set in `project.yml`.
Unlike the Mac target, there is no `scripts/release.sh`-equivalent script yet —
archive and upload through Xcode Organizer (`Product ▸ Archive` on the
`AnglesiteMobile` scheme, then `Distribute App ▸ TestFlight & App Store`) or
`xcodebuild -exportArchive` by hand. Scripting this pipeline is a reasonable
follow-up once the manual flow is exercised a few times, but is out of scope
for #1434.

### One-Time Setup

1. **App Store Connect app record.** Create an app for bundle id
   `io.dwk.anglesite.ios` in [App Store Connect](https://appstoreconnect.apple.com/).
   As with the Mac app, the build will not upload until the record exists. This
   can reuse the same Apple Developer team as the Mac app's record.

2. **Certificates and provisioning profile.** An **Apple Distribution**
   certificate (can be the same one the Mac app uses — it's not
   platform-specific) plus an **iOS App Store** provisioning profile for
   `io.dwk.anglesite.ios`, tied to that certificate.

3. **App Store Connect API key.** Reuse the same key created for the Mac app's
   release pipeline (see "One-Time Setup" step 5 above) — App Store Connect API
   keys are account-wide, not per-app.

### Entitlements traced to features

Per the design spec §4, each entry in `Resources/AnglesiteMobile.entitlements`
must trace to a shipped feature — no speculative capabilities:

| Entitlement | Feature | Status |
|---|---|---|
| `com.apple.developer.icloud-container-identifiers` / `icloud-services` (`CloudDocuments`) | iCloud site discovery (#866) | Shipped |
| `com.apple.developer.associated-domains` (`webcredentials:auth.anglesite.dwk.io`) | Cloudflare OAuth callback interception (#891) | Shipped |
| CloudKit (P2P signaling mailbox) | Anywhere-runtime pairing (#1208 P2) | **Not yet added** — belongs in that feature's PR, not here |
| Camera usage description (QR pairing scan) | "Edit Site" pairing onboarding (#1431) | **Not yet added** — belongs in that feature's PR, not here |
| Keychain | Cloudflare token / pinned device keys | No entitlement needed — standard Keychain Services API, no keychain-sharing group |

Deliberately absent: local-network entitlement, background modes — the phone
dials out per-session only (design spec §4).

### Privacy manifest and export compliance

- `Resources/PrivacyInfo.xcprivacy` is linked into the `AnglesiteMobile` target
  (shared with the Mac target — see the comment in `project.yml`). No
  `NSPrivacyCollectedDataTypes` entries: site content stays in the owner's own
  iCloud container, never collected by or sent to us.
- `Resources/Info-iOS.plist` declares `ITSAppUsesNonExemptEncryption=false`,
  matching today's shipped feature set (standard HTTPS/TLS only). Re-verify
  once the WebRTC/DTLS transport (#1208 P4) ships — DTLS-SRTP as implemented by
  a standard, unmodified library typically still qualifies for the standard
  exemption, but confirm before assuming the flag stays `false`.

### App Review demo path

A reviewer has no paired Mac. Per the design spec §4, the app must be
reviewable standalone:

- Micropub posting (#869) works against any IndieAuth-capable site — provide a
  demo account's credentials in the review notes.
- "Edit Site" with no paired Mac must show the pairing explainer, never a dead
  end (design spec §3) — once #1431 ships, confirm this path works with no
  setup before submitting.
- Include a demo video of the full paired-editing flow in the review notes,
  since a reviewer cannot exercise Mac pairing themselves.

### TestFlight and submission

Once the app record and provisioning above exist, TestFlight distribution and
App Review submission follow the same shape as the Mac app's "TestFlight Beta
Distribution" section — Internal Testing needs no Beta App Review, External
Testing's first build does, and full App Store submission is the v2.0 exit
criterion per the design spec.
