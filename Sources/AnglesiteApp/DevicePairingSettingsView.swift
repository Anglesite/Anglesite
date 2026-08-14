import SwiftUI
import AppKit
import CoreImage
import AnglesiteCore

/// "Anglesite on iPhone/iPad" Settings pane (#1208 P2 design spec §6 Settings UI) — the owner-facing
/// half of Anywhere-runtime pairing. Shows a QR code that hands a phone this Mac's pairing identity
/// (`{deviceID, publicKey}`), plus the list of already-paired devices with a Revoke action. Mirrors
/// `AgentsSettingsView`'s `Form { Section { ... } }` shape and `ForEach`/`Button("Remove")` row
/// pattern (`Sources/AnglesiteApp/SettingsView.swift`) exactly, substituting "Revoke" for "Remove"
/// per the design spec's own wording.
///
/// Unlike `AgentsSettingsView.remove(_:)`, revoking a paired device does **not** touch the Keychain:
/// `PairedDevice.pinnedPublicKey` is not a secret (integrity, not confidentiality, is what a pinned
/// key protects — design spec §Pairing and security), so there is nothing to clear beyond the
/// `PairedDeviceStore` record itself.
struct DevicePairingSettingsView: View {
    @State private var qrImage: NSImage?
    @State private var devices: [PairedDevice] = []
    @State private var loadError: String?

    private let store = PairedDeviceStore()

    var body: some View {
        Form {
            Section("Pair a Device") {
                HStack {
                    Spacer()
                    Group {
                        if let qrImage {
                            Image(nsImage: qrImage)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 180, height: 180)
                                .accessibilityLabel("Pairing QR code")
                        } else {
                            ProgressView()
                                .frame(width: 180, height: 180)
                        }
                    }
                    Spacer()
                }
                Text("Open the Anglesite app on your iPhone or iPad and scan this code to pair it with this Mac. The code carries this Mac's device ID and public key — nothing leaves your iCloud account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let loadError {
                    Text(loadError).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Paired Devices") {
                if devices.isEmpty {
                    Text("No devices paired yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(devices) { device in
                    LabeledContent(device.displayName) {
                        HStack(spacing: 8) {
                            Text(lastConnectedSummary(device))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Revoke") { revoke(device) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        // Regenerated in-memory only, once per Settings-window session — never written to disk —
        // matching the design spec's "generated fresh each time the pane appears, not persisted".
        .task {
            reloadDevices()
            generateQRCode()
        }
    }

    private func lastConnectedSummary(_ device: PairedDevice) -> String {
        guard let lastConnectedAt = device.lastConnectedAt else { return "Never connected" }
        return lastConnectedAt.formatted(date: .abbreviated, time: .shortened)
    }

    private func reloadDevices() {
        do {
            devices = try store.load()
            loadError = nil
        } catch {
            loadError = "couldn't load paired devices: \(error.localizedDescription)"
        }
    }

    private func revoke(_ device: PairedDevice) {
        do {
            try store.remove(id: device.id)
            reloadDevices()
        } catch {
            loadError = "couldn't revoke \(device.displayName): \(error.localizedDescription)"
        }
    }

    /// Builds this Mac's pairing QR code: reads (or generates and Keychain-persists, on first use)
    /// this device's `DevicePairingKeyPair`, then encodes `{deviceID, publicKey}` — the same field
    /// names `DeviceAnnounceRecord` uses — as the QR payload.
    private func generateQRCode() {
        do {
            // #1208 P2, shared-key follow-up: the key published in this QR code is the one *this*
            // bundle ID can see. The `AnglesiteRemote` helper reads the same service/account but
            // through its own sandbox-implicit keychain access group, so it signs signaling
            // payloads with a different key and a phone that pinned this QR rejects it. One-line
            // fix, once both bundles carry the group in a `keychain-access-groups` entitlement:
            //     KeychainStore(accessGroup: KeychainStore.sharedPairingAccessGroup)
            // Blocked on the Apple Developer portal capability — checklist in
            // `Resources/AnglesiteRemote.entitlements` ▸ manual portal step 2. Do not switch this
            // over before that lands: an unentitled access group makes SecItem reject the call, so
            // QR generation would start failing outright instead of merely mismatching.
            let keychain = KeychainStore()
            let keyPair: DevicePairingKeyPair
            if let existing = try keychain.readDevicePairingKeyPair() {
                keyPair = existing
            } else {
                let fresh = DevicePairingKeyPair()
                try keychain.writeDevicePairingKeyPair(fresh)
                keyPair = fresh
            }

            let payload = PairingQRPayload(deviceID: Self.ownDeviceID(), publicKey: keyPair.publicKeyData)
            let payloadData = try JSONEncoder().encode(payload)
            guard let image = Self.qrCodeImage(from: payloadData) else {
                loadError = "couldn't render the pairing QR code."
                return
            }
            qrImage = image
            loadError = nil
        } catch {
            loadError = "couldn't prepare pairing key: \(error.localizedDescription)"
        }
    }

    /// This Mac's own stable device identifier — the opaque string a peer addresses this Mac's
    /// `DeviceAnnounceRecord` by once Task 9 wires up the real CloudKit announce. Generated once
    /// and persisted directly in `UserDefaults.standard` (not routed through `AppSettings`, which
    /// is out of scope for this Settings-UI-only task) rather than regenerated per QR render —
    /// unlike the QR image itself, this identifier must stay the same across app relaunches so a
    /// previously scanned QR (or a re-announce) still resolves to this Mac.
    private static func ownDeviceID() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: ownDeviceIDDefaultsKey), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: ownDeviceIDDefaultsKey)
        return fresh
    }

    private static let ownDeviceIDDefaultsKey = "anglesite.pairingOwnDeviceID"

    /// Renders `data` as a QR code image via `CIFilter(name: "CIQRCodeGenerator")` at "M" error
    /// correction, scaled up from the filter's native one-point-per-module output so it reads
    /// clearly at the 180×180 display size above.
    private static func qrCodeImage(from data: Data) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let outputImage = filter.outputImage else { return nil }

        let scale: CGFloat = 8
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaledImage)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

/// The QR payload's wire shape — field names match `DeviceAnnounceRecord`'s CloudKit fields
/// (`deviceID`, `publicKey`). `publicKey` encodes as base64 via `JSONEncoder`'s default `Data`
/// strategy, matching how `DevicePairingKeyPair.publicKeyData` round-trips elsewhere in this
/// pairing flow (e.g. `SecretStore.writeDevicePairingKeyPair`).
private struct PairingQRPayload: Encodable {
    let deviceID: String
    let publicKey: Data
}

#Preview {
    DevicePairingSettingsView()
}
