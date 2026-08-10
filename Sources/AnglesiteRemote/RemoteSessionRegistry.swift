import Foundation
import os.log

/// One process's claim on a site's running container, published so another process asking
/// "is someone already serving this site?" can bridge to the same ports instead of booting a
/// second container (design spec §Architecture 5, "one container owner per site, always").
public struct RemoteSessionClaim: Codable, Sendable, Equatable {
    public var siteID: String
    public var previewURL: URL
    public var mcpURL: URL
    public var ownerPID: Int32

    public init(siteID: String, previewURL: URL, mcpURL: URL, ownerPID: Int32) {
        self.siteID = siteID
        self.previewURL = previewURL
        self.mcpURL = mcpURL
        self.ownerPID = ownerPID
    }
}

/// Directory-backed registry: one `<siteID>.json` file per claim, written atomically. Any
/// process sharing the directory can publish/look up/withdraw a claim. Production wiring points
/// this at the App Group container (blocked on the Apple Developer portal step in Task 6 Step
/// 5); tests inject a temp directory — the type itself has no opinion about *which* directory.
public actor RemoteSessionRegistry {
    private let directory: URL
    private static let logger = os.Logger(subsystem: "io.dwk.anglesite.remote", category: "RemoteSessionRegistry")

    public init(directory: URL) {
        self.directory = directory
    }

    /// Publishes (or replaces) this process's claim. Overwrites any existing claim for the same
    /// `siteID` unconditionally — a stale claim from a crashed owner is handled by
    /// `RemoteContainerSession`'s liveness check (Task 5), not by this type.
    public func publish(_ claim: RemoteSessionClaim) throws {
        let filename = Self.encodedFilename(for: claim.siteID)
        let fileURL = directory.appendingPathComponent(filename)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(claim)

        try data.write(to: fileURL, options: .atomic)
    }

    /// Reads the current claim for `siteID`, or `nil` if none exists.
    public func lookup(siteID: String) throws -> RemoteSessionClaim? {
        let filename = Self.encodedFilename(for: siteID)
        let fileURL = directory.appendingPathComponent(filename)

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            let claim = try decoder.decode(RemoteSessionClaim.self, from: data)
            return claim
        } catch let nsError as NSError where nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError {
            // File doesn't exist (never published, or withdrawn by another process) — return nil
            return nil
        } catch let decodingError as DecodingError {
            // Malformed claim — log and rethrow to surface the corruption
            Self.logger.error("Failed to decode claim at \(fileURL.path)")
            throw decodingError
        } catch let ioError {
            // Other IO errors — log and rethrow
            Self.logger.error("IO error reading claim at \(fileURL.path): \(ioError.localizedDescription)")
            throw ioError
        }
    }

    /// Removes the claim for `siteID`. Safe to call when none exists.
    public func withdraw(siteID: String) throws {
        let filename = Self.encodedFilename(for: siteID)
        let fileURL = directory.appendingPathComponent(filename)

        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            // File doesn't exist (already withdrawn, or never published, or withdrawn by another process) — no-op
            return
        } catch {
            // Other errors — log and rethrow
            Self.logger.error("Error removing claim at \(fileURL.path): \(error.localizedDescription)")
            throw error
        }
    }

    /// Encodes a siteID into a filesystem-safe filename using percent-encoding.
    /// This ensures arbitrary siteID strings (UUIDs, etc.) never introduce path traversal
    /// or other filesystem risks.
    private static func encodedFilename(for siteID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let encoded = siteID.addingPercentEncoding(withAllowedCharacters: allowed) ?? siteID
        return "\(encoded).json"
    }
}
