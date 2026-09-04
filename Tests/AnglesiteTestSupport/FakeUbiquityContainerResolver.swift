import Foundation
import AnglesiteCore

/// A `UbiquityContainerResolving` stand-in that answers a fixed URL (or `nil`, simulating iCloud
/// being unavailable) — used across `AnglesiteIntentsTests`, `AnglesiteAppTests`,
/// `AnglesiteCoreTests`, and `AnglesiteIOSTests`.
public struct FakeUbiquityContainerResolver: UbiquityContainerResolving {
    public let result: URL?

    public init(result: URL?) {
        self.result = result
    }

    public func url(forUbiquityContainerIdentifier containerIdentifier: String?) -> URL? { result }
}
