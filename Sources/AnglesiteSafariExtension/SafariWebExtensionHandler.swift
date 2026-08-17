import SafariServices
import os.log

/// Required principal class for a Manifest V3 Safari Web Extension (`NSExtensionPrincipalClass`
/// in Info.plist). This extension does no native messaging in v1 — detection, badge state, and
/// the popup UI are entirely the web extension's own JS (`Resources/SafariExtension/`) — so this
/// handler only needs to satisfy Safari's requirement that an app-extension bundle has a
/// principal class conforming to `NSExtensionRequestHandling`. It logs and echoes any message
/// it's asked to handle rather than silently dropping it (see `AGENTS.md` ▸ "Logs are sacred").
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private let log = OSLog(subsystem: "io.dwk.anglesite.SafariExtension", category: "native-messaging")

    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey]

        os_log(.info, log: log, "Received unexpected native message: %{public}@", String(describing: message))

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: ["received": true]]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}
