import Foundation
import Observation
import AnglesiteCore

/// Drives the first-run pairing walk-in on iOS (#1431, iOS v2.0 design §3): the owner's first
/// "Edit Site" tap with no paired Mac lands on an explainer, asks for camera access *in that
/// moment* (platform spec §5 — permission in context, not at launch), scans the QR code the Mac
/// shows in Settings ▸ Devices, and pins the Mac via `PairedDeviceStore`. Camera access and
/// persistence are injected so the flow is fully testable off-device; the camera *frames*
/// arrive from the view layer's scanner, which forwards each decoded string here.
@MainActor
@Observable
public final class PairingOnboardingModel {
    /// Where the walk-in currently is. Every state renders as guidance, never a dead end
    /// (design §3: "an honest explainer").
    public enum Step: Equatable {
        /// What pairing is and what it requires — the resting entry state.
        case explainer
        /// Camera access was declined; the view offers the Settings app as the way forward.
        case cameraDenied
        /// The camera is live; awaiting the first decodable frame.
        case scanning
        /// A scan or the persistence step failed; `message` is owner-facing.
        case failed(message: String)
        /// A Mac is pinned; the caller proceeds into the session.
        case done
    }

    public private(set) var step: Step = .explainer

    private let requestCameraAccess: () async -> Bool
    private let storeDevice: (PairedDevice) throws -> Void

    /// - Parameters:
    ///   - requestCameraAccess: `AVCaptureDevice.requestAccess(for: .video)` in production —
    ///     injected because the capture stack doesn't exist under `swift test` on macOS.
    ///   - storeDevice: `PairedDeviceStore().add` in production.
    public init(
        requestCameraAccess: @escaping () async -> Bool,
        storeDevice: @escaping (PairedDevice) throws -> Void
    ) {
        self.requestCameraAccess = requestCameraAccess
        self.storeDevice = storeDevice
    }

    /// Asks for the camera (first call shows the system prompt) and opens the scanner, or lands
    /// on the honest denied state. Callable from `.explainer`, `.cameraDenied` (the owner may
    /// have granted access in Settings and come back), and `.failed`.
    public func beginScan() async {
        guard step != .scanning, step != .done else { return }
        step = await requestCameraAccess() ? .scanning : .cameraDenied
    }

    /// Consumes one decoded QR string from the scanner. Only the first accepted code wins — the
    /// camera keeps emitting frames of the same code, so everything after `.done` is ignored.
    public func handleScanned(_ code: String) {
        guard step == .scanning else { return }
        guard let payload = try? DevicePairingPayload.decode(from: code) else {
            step = .failed(message: String(localized: "That code isn't an Anglesite pairing code. Show the code in Anglesite's settings on your Mac and try again."))
            return
        }
        let device = PairedDevice(
            deviceID: payload.deviceID,
            displayName: String(localized: "My Mac"),
            pinnedPublicKey: payload.publicKey,
            pairedAt: Date()
        )
        do {
            try storeDevice(device)
            step = .done
        } catch {
            step = .failed(message: String(localized: "Couldn't save the pairing on this device. Try again."))
        }
    }

    /// Back to the explainer after a failure (or a cancelled scan).
    public func retry() {
        guard step != .done else { return }
        step = .explainer
    }
}
