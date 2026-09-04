import SwiftUI
import AppKit
import AnglesiteCore

/// Quick-capture compose sheet (#531): URL + fetched title + commentary become an entry in the
/// site's `bookmarks` collection, saved as a draft or published. Presented from a site window
/// (fixed site), the launcher (site picker), or File ▸ New Link Post….
struct QuickCaptureSheet: View {
    /// Sites for the picker, or nil when the sheet is bound to one site (site-window flow).
    let pickerSites: [SiteStore.Site]?
    let fetchMetadata: @Sendable (URL) async throws -> LinkMetadata
    /// `siteID` is the picker selection (nil in the site-window flow, which ignores it).
    /// `imageURL` is the fetched `og:image`, if the page had a usable one — the creator downloads
    /// it into the site's assets after the entry is written (#1451).
    let onCreate: (_ siteID: String?, _ title: String, _ urlString: String, _ commentary: String, _ imageURL: String?, _ draft: Bool) async -> ContentCreateResult

    @Environment(\.dismiss) private var dismiss
    @State private var urlString: String
    @State private var title = ""
    @State private var commentary = ""
    @State private var selectedSiteID: String?
    @State private var isFetching = false
    @State private var fetchFailed = false
    /// The URL whose fetch already ran (successfully or not) — dedupes the `.task(id:)` restart.
    @State private var fetchedURLString: String?
    /// The `og:image` of the page currently in the URL field, absolute and http(s) (the fetcher
    /// resolves and gates it). Cleared whenever the URL moves to a different page, so a captured
    /// card image can never belong to a page the owner already left (#1451).
    @State private var fetchedImageURL: String?
    @State private var isCreating = false
    @State private var errorMessage: String?

    init(
        pickerSites: [SiteStore.Site]?,
        defaultSiteID: String?,
        initialURLString: String,
        fetchMetadata: @escaping @Sendable (URL) async throws -> LinkMetadata,
        onCreate: @escaping (_ siteID: String?, _ title: String, _ urlString: String, _ commentary: String, _ imageURL: String?, _ draft: Bool) async -> ContentCreateResult
    ) {
        self.pickerSites = pickerSites
        self.fetchMetadata = fetchMetadata
        self.onCreate = onCreate
        _urlString = State(initialValue: initialURLString)
        _selectedSiteID = State(initialValue: defaultSiteID ?? pickerSites?.first?.id)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Link Post") {
                    TextField("URL", text: $urlString, prompt: Text(verbatim: "https://example.com/article"))
                    HStack {
                        TextField("Title", text: $title, prompt: Text("optional"))
                        if isFetching {
                            ProgressView().controlSize(.small)
                        }
                    }
                    TextField("Commentary", text: $commentary, axis: .vertical)
                        .lineLimit(3...8)
                    if let pickerSites {
                        Picker("Site", selection: $selectedSiteID) {
                            ForEach(pickerSites, id: \.id) { site in
                                Text(site.name).tag(Optional(site.id))
                            }
                        }
                    }
                    if hasMalformedURL {
                        Text("Enter an absolute URL, e.g. https://example.com/article")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else if fetchFailed {
                        Text("Couldn't fetch the page's info — you can still add your own title.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 460, minHeight: 300)
            .navigationTitle("New Link Post")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isCreating)
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    // Return commits the safe verb: new entries are drafts by default (#798),
                    // and Publish goes live at the next deploy — that takes an explicit click,
                    // never a reflexive Return in the URL/Title field.
                    Button(isCreating ? "Working…" : "Save Draft") { create(draft: true) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canCreate)
                    Button("Publish") { create(draft: false) }
                        .disabled(!canCreate)
                }
            }
        }
        // Fetch (debounced) whenever the URL settles on a new valid value; the title stays
        // editable throughout and a user-typed title is never overwritten (spec §4.1/§4.2).
        .task(id: urlString) {
            // A URL edit cancels the in-flight task and starts this one. The cancelled task is
            // barred (guards below) from touching state it no longer owns — including its
            // `defer` — so the fresh task clears the stale spinner itself.
            isFetching = false
            let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ContentFieldValidation.isAbsoluteURL(trimmed),
                  trimmed != fetchedURLString,
                  let url = URL(string: trimmed) else { return }
            // Before the debounce, not after: a Save during the sleep must not attach the previous
            // page's card image to this one.
            fetchedImageURL = nil
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            isFetching = true
            fetchFailed = false
            defer { if !Task.isCancelled { isFetching = false } }
            do {
                let metadata = try await fetchMetadata(url)
                // Cancellation is cooperative: a stale task's fetch can still return (or throw)
                // after a newer task started. Its results describe a URL the user already left.
                guard !Task.isCancelled else { return }
                fetchedURLString = trimmed
                if title.isEmpty, let fetched = metadata.title { title = fetched }
                fetchedImageURL = metadata.imageURL
            } catch {
                guard !Task.isCancelled else { return }
                fetchedURLString = trimmed
                fetchFailed = true
            }
        }
    }

    private var trimmedURL: String {
        urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasMalformedURL: Bool {
        !trimmedURL.isEmpty && !ContentFieldValidation.isAbsoluteURL(trimmedURL)
    }

    private var canCreate: Bool {
        !isCreating
            && ContentFieldValidation.isAbsoluteURL(trimmedURL)
            && (pickerSites == nil || selectedSiteID != nil)
    }

    private func create(draft: Bool) {
        let cleanURL = trimmedURL
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanCommentary = commentary.trimmingCharacters(in: .whitespacesAndNewlines)
        isCreating = true
        errorMessage = nil
        Task {
            let result = await onCreate(
                selectedSiteID, cleanTitle, cleanURL, cleanCommentary, fetchedImageURL, draft)
            await MainActor.run {
                isCreating = false
                switch result {
                case .created:
                    dismiss()
                case .siteNotFound:
                    errorMessage = String(localized: "This site is no longer available.")
                case .failed(let reason):
                    errorMessage = reason
                }
            }
        }
    }
}

/// Shared quick-capture plumbing used by the sheet's presenters (#531).
enum QuickCapture {
    /// A web URL currently on the general pasteboard, or nil. Only http(s) — a file path or
    /// mailto: on the clipboard must not open the compose sheet.
    @MainActor
    static func clipboardURLString() -> String? {
        let pasteboard = NSPasteboard.general
        let candidate = (pasteboard.string(forType: .URL) ?? pasteboard.string(forType: .string))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Scheme match is case-insensitive (RFC 3986; `HTTP://…` is valid and
        // `isAbsoluteURL` accepts it) — same `.lowercased()` pattern as the rest of the
        // codebase's scheme checks.
        guard let candidate else { return nil }
        let lowercased = candidate.lowercased()
        guard lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://"),
              ContentFieldValidation.isAbsoluteURL(candidate) else { return nil }
        return candidate
    }

    /// First http(s) URL in a drop payload, or nil (lets `.anglesite` package drops pass through).
    static func webURL(from urls: [URL]) -> URL? {
        urls.first { $0.scheme?.lowercased() == "http" || $0.scheme?.lowercased() == "https" }
    }

    /// Windowless create for the launcher flow: same native path the intents use
    /// (`Bootstrap.swift`'s resolver), no content graph (the site has no open window to
    /// refresh; an open window's file watcher picks the new file up on its own). Delegates the
    /// actual create+card-image logic to `LinkPostCreation` (#1450), shared with the share
    /// extension's compose flow.
    static func createLinkPost(
        siteID: String, title: String, urlString: String, commentary: String,
        imageURL: String?, draft: Bool
    ) async -> ContentCreateResult {
        // Resolved once and shared with LinkPostCreation — re-querying SiteStore after the write
        // would be a second actor hop, and a site closed in between the two lookups would
        // silently skip the card image for an entry the first lookup just wrote (#1451).
        let sourceDirectory = await SiteStore.shared.find(id: siteID)?.sourceDirectory
        return await LinkPostCreation.create(
            siteID: siteID, title: title, urlString: urlString, commentary: commentary,
            imageURL: imageURL, draft: draft, sourceDirectory: sourceDirectory)
    }
}
