# Flatpak packaging for AnglesiteLinux

**Status: live-verified (#1293).** Built and run end-to-end on a real Ubuntu 26.04/aarch64 GTK
box: `flatpak-builder` builds the manifest, the app boots, opening a `.anglesite` package through
the document-portal folder picker bind-mounts correctly into a real podman container launched via
`flatpak-spawn --host`, and the Astro preview serves. See
[`docs/superpowers/specs/2026-08-06-flatpak-packaging-investigation.md`](../../docs/superpowers/specs/2026-08-06-flatpak-packaging-investigation.md)
for the design rationale and §9 for the verification record. A CI lane (`linux-flatpak-build` in
`.github/workflows/ci.yml`) now builds this manifest and runs `AnglesiteLinuxTests` on every PR.

## Files

- `io.dwk.anglesite.linux.yml` — the `flatpak-builder` manifest.
- `io.dwk.anglesite.linux.desktop` — desktop entry.
- `io.dwk.anglesite.linux.metainfo.xml` — AppStream metadata (placeholder release entry).
- `icons/io.dwk.anglesite.linux.svg` — placeholder app icon, not final brand art.

## Building and running locally

1. Install Flatpak + `flatpak-builder`, and add Flathub for the `org.gnome.Platform`/
   `org.gnome.Sdk` runtime and the `org.freedesktop.Sdk.Extension.swift6` extension. The
   extension branch must be pinned explicitly — `flatpak install --noninteractive` fails on an
   ambiguous ref otherwise, since Flathub currently carries both `//24.08` and `//25.08` for it;
   `org.gnome.Sdk//50` itself is built against freedesktop runtime 25.08:
   ```sh
   flatpak remote-add --if-not-exists --user flathub https://flathub.org/repo/flathub.flatpakrepo
   flatpak install --user flathub org.gnome.Platform//50 org.gnome.Sdk//50 org.freedesktop.Sdk.Extension.swift6//25.08
   ```
2. Build the edit overlay first (the manifest installs its output, but doesn't build it —
   building it needs npm, which a real Flathub-submittable build can't reach; see the manifest's
   own comment on this):
   ```sh
   scripts/build-overlay.sh
   ```
3. From the repo root (the manifest's `build-args: [--share=network]` lets this build resolve
   SwiftPM's git-pinned dependencies — see the manifest's own comment; this makes local
   verification builds work but is **not** Flathub-submittable as-is, see "Known gaps" below):
   ```sh
   flatpak-builder --user --install --force-clean \
     packaging/flatpak/build-dir packaging/flatpak/io.dwk.anglesite.linux.yml
   ```
4. `flatpak run io.dwk.anglesite.linux`, open a `.anglesite` package via the folder picker, and
   confirm the preview boots. `AnglesiteLinuxTests` (and, once
   [#1284](https://github.com/Anglesite/Anglesite/issues/1284) purity-sweeps `AnglesiteCoreTests`
   onto Linux, `PodmanContainerControlTests`/`DocumentPortalResolutionTests` too) run inside the
   same sandbox non-interactively via `flatpak-builder --build-shell`:
   ```sh
   flatpak-builder --build-shell=anglesite-linux packaging/flatpak/build-dir packaging/flatpak/io.dwk.anglesite.linux.yml <<'EOF'
   ANGLESITE_LINUX_SHELL=1 swift test --filter AnglesiteLinuxTests
   exit
   EOF
   ```

## Known gaps (see the investigation doc §8-9 for the full list)

- `PodmanContainerControlTests`/`DocumentPortalResolutionTests` don't run in CI yet —
  `AnglesiteCoreTests` isn't in `Package.swift`'s off-Darwin `portableTargets` set (it also pulls
  in `AnglesiteTestSupport`, itself not purity-swept), tracked in
  [#1284](https://github.com/Anglesite/Anglesite/issues/1284).
- Not Flathub-submittable as-is: both the SwiftPM build step (`--share=network` in `build-options`,
  needed to fetch git-pinned dependencies) and the overlay JS's npm dependencies (built outside
  the sandboxed build step entirely, per step 2 above) need their dependencies vendored ahead of
  time for a real hermetic Flathub build — tracked in #1293.
- No path exists yet for an end user to obtain the `localhost/anglesite-dev:latest` image this
  app requires — today it's only produced by a developer running
  `scripts/build-podman-image.sh` against a sibling checkout — tracked in #1291.
- No MIME-type association for `.anglesite` packages is registered (Linux has no direct
  equivalent of macOS's `io.dwk.anglesite.site` package UTI without a separate
  `shared-mime-info` XML registration) — "Open Site…" via the in-app folder picker works
  regardless; double-click-to-open from a file manager doesn't yet.
- Icon is a placeholder, not final brand art.
- Not submitted to Flathub — this is a locally-buildable manifest only.
