import Foundation
import Testing
import AnglesiteCore
@testable import AnglesiteIOS

@MainActor
@Suite("PairingOnboardingModel")
struct PairingOnboardingModelTests {
    private final class StoredDevices: @unchecked Sendable {
        var devices: [PairedDevice] = []
        var error: Error?
    }

    private func makeModel(
        cameraGranted: Bool = true,
        stored: StoredDevices = StoredDevices()
    ) -> PairingOnboardingModel {
        PairingOnboardingModel(
            requestCameraAccess: { cameraGranted },
            storeDevice: { device in
                if let error = stored.error { throw error }
                stored.devices.append(device)
            }
        )
    }

    private func validCode(deviceID: String = "mac-1", key: Data = Data([0x04, 0x01])) throws -> String {
        let json = try DevicePairingPayload(deviceID: deviceID, publicKey: key).encodedJSON()
        return String(decoding: json, as: UTF8.self)
    }

    @Test("granted camera access moves explainer → scanning")
    func beginScanGranted() async {
        let model = makeModel(cameraGranted: true)
        #expect(model.step == .explainer)
        await model.beginScan()
        #expect(model.step == .scanning)
    }

    @Test("denied camera access lands on the honest denied state")
    func beginScanDenied() async {
        let model = makeModel(cameraGranted: false)
        await model.beginScan()
        #expect(model.step == .cameraDenied)
    }

    @Test("a valid code pins the Mac and finishes")
    func scanValidCode() async throws {
        let stored = StoredDevices()
        let model = makeModel(stored: stored)
        await model.beginScan()
        let key = Data([0x04, 0xAA])
        model.handleScanned(try validCode(deviceID: "mac-42", key: key))
        #expect(model.step == .done)
        #expect(stored.devices.count == 1)
        #expect(stored.devices.first?.deviceID == "mac-42")
        #expect(stored.devices.first?.pinnedPublicKey == key)
    }

    @Test("garbage scans fail with an owner-comprehensible message")
    func scanGarbage() async {
        let model = makeModel()
        await model.beginScan()
        model.handleScanned("https://example.com/not-a-pairing-code")
        guard case .failed = model.step else {
            Issue.record("expected .failed, got \(model.step)")
            return
        }
    }

    @Test("frames after the first accepted code are ignored")
    func ignoresAfterDone() async throws {
        let stored = StoredDevices()
        let model = makeModel(stored: stored)
        await model.beginScan()
        model.handleScanned(try validCode())
        model.handleScanned(try validCode(deviceID: "mac-2"))
        #expect(model.step == .done)
        #expect(stored.devices.count == 1)
    }

    @Test("a store failure surfaces as failed, not silent success")
    func storeFailure() async throws {
        let stored = StoredDevices()
        stored.error = CocoaError(.fileWriteNoPermission)
        let model = makeModel(stored: stored)
        await model.beginScan()
        model.handleScanned(try validCode())
        guard case .failed = model.step else {
            Issue.record("expected .failed, got \(model.step)")
            return
        }
        #expect(stored.devices.isEmpty)
    }

    @Test("retry returns to the explainer")
    func retryFromFailure() async {
        let model = makeModel()
        await model.beginScan()
        model.handleScanned("junk")
        model.retry()
        #expect(model.step == .explainer)
    }
}
