import Foundation

/// Shared wording for command seams whose host-side implementation was removed when the embedded
/// Node runtime was retired (#70). Centralizing this keeps the message consistent across
/// `DeployCommand`, `DeployExecutor`, `AuditCommand`, `AstroHTMLValidator`, and
/// `SocialWorkerProvisionCommand` as their default resolvers were each updated independently.
enum HostNodeRetirement {
    static func reason(_ action: String) -> String {
        "\(action) must run in the container runtime; host Node has been retired"
    }
}
