import SwiftUI
import AVFoundation
import UIKit
import AnglesiteCore
import AnglesiteIOS

/// The pairing walk-in the first "Edit Site" tap lands on when no Mac is paired (#1431, design
/// §3): explainer → in-context camera permission → QR scan → pinned Mac. Every state offers a
/// way forward — an honest explainer, never a dead end.
struct PairingOnboardingScreen: View {
    let model: PairingOnboardingModel
    /// Fired once the Mac is pinned; the session screen proceeds into the session.
    var onPaired: () -> Void

    var body: some View {
        Group {
            switch model.step {
            case .explainer:
                ContentUnavailableView {
                    Label("Pair Your Mac", systemImage: "qrcode.viewfinder")
                } description: {
                    Text("Editing your site happens through your Mac. In Anglesite on your Mac, open Settings, choose Devices, then scan the pairing code shown there.")
                } actions: {
                    Button("Scan Pairing Code") {
                        Task { await model.beginScan() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            case .cameraDenied:
                ContentUnavailableView {
                    Label("Camera Access Needed", systemImage: "camera")
                } description: {
                    Text("Scanning the pairing code needs the camera. You can allow camera access for Anglesite in Settings.")
                } actions: {
                    Button("Open Settings") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }
                    .buttonStyle(.borderedProminent)
                    // The owner may have granted access in Settings and come back.
                    Button("Try Again") {
                        Task { await model.beginScan() }
                    }
                }
            case .scanning:
                QRScannerView { model.handleScanned($0) }
                    .ignoresSafeArea()
                    .overlay(alignment: .bottom) {
                        Text("Point the camera at the pairing code on your Mac.")
                            .font(.callout)
                            .padding(10)
                            .background(.thinMaterial, in: .capsule)
                            .padding(.bottom, 24)
                    }
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Cancel") { model.retry() }
                        }
                    }
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't Pair", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(verbatim: message)
                } actions: {
                    Button("Try Again") {
                        Task {
                            model.retry()
                            await model.beginScan()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            case .done:
                // Momentary: onChange below hands off to the session immediately.
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: model.step) { _, newStep in
            if newStep == .done { onPaired() }
        }
    }
}
