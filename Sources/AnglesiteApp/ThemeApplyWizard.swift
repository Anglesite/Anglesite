// Sources/AnglesiteApp/ThemeApplyWizard.swift
import SwiftUI
import AnglesiteCore

struct ThemeApplyWizard: View {
    @Bindable var model: ThemeApplyWizardModel
    /// Called when the owner dismisses a finished wizard (the applying step's "Done" button).
    /// The caller nils its `.sheet(item:)` model, matching every other wizard/sheet in
    /// `SiteWindow` (`IntegrationWizard`'s `onClose`, `EmailSetupSheetView`'s `onDone`) rather
    /// than relying on `@Environment(\.dismiss)` to clear an item-bound sheet's identity.
    let onDone: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Group {
                switch model.step {
                case .pickSource: pickSourceStep
                case .pickBuiltIn: pickBuiltInStep
                case .browseFreedesignmd: browseFreedesignmdStep
                case .review: reviewStep
                case .applying: applyingStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack {
                if model.step != .pickSource, model.step != .applying {
                    Button("Back") { model.back() }
                }
                Spacer()
                if model.step == .review {
                    Button("Apply") { Task { await model.apply() } }
                        .buttonStyle(.borderedProminent)
                } else if model.step != .applying {
                    Button("Continue") { Task { await model.advance() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canContinue)
                }
            }
        }
        .padding(20)
        .frame(width: 480, height: 420)
    }

    private var pickSourceStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Source", selection: Binding(get: { model.source }, set: { model.source = $0 })) {
                Text("Built-in themes").tag(ThemeApplyWizardModel.Source?.some(.builtIn))
                Text("Browse freedesignmd.com").tag(ThemeApplyWizardModel.Source?.some(.freedesignmd))
            }
            .pickerStyle(.radioGroup)
        }
    }

    private var pickBuiltInStep: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(model.catalog.themes) { theme in
                    ThemeApplyCard(theme: theme, isSelected: model.selectedBuiltInID == theme.id) {
                        model.selectedBuiltInID = theme.id
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var browseFreedesignmdStep: some View {
        Group {
            if let error = model.fetchError {
                Text(error).foregroundStyle(.secondary)
            } else if model.freedesignmdCandidates.isEmpty {
                ProgressView("Searching freedesignmd.com…")
            } else {
                List(model.freedesignmdCandidates, selection: Binding(
                    get: { model.selectedFreedesignmdSlug },
                    set: { model.selectedFreedesignmdSlug = $0 }
                )) { system in
                    Text(system.name).tag(system.slug)
                }
            }
        }
    }

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.source {
            case .builtIn:
                if let theme = model.selectedBuiltInTheme {
                    Text(theme.name).font(.headline)
                    Text(theme.blurb).foregroundStyle(.secondary)
                    contrastSection
                }
            case .freedesignmd:
                if let slug = model.selectedFreedesignmdSlug {
                    Text(slug).font(.headline)
                }
            case nil: EmptyView()
            }
        }
    }

    /// Advisory readability findings for the selected theme's colours (#2021). Never blocks Apply;
    /// each row shows the pairing as it would render and offers a one-click fix, so the owner
    /// judges by eye rather than by a contrast ratio.
    @ViewBuilder
    private var contrastSection: some View {
        let findings = model.contrastFindings
        if !findings.isEmpty {
            Divider().padding(.vertical, 4)
            HStack {
                Text("Readability").font(.subheadline.bold())
                Spacer()
                if findings.contains(where: { $0.suggestedValue != nil }) {
                    Button("Fix All") { model.fixAllContrast() }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(findings) { finding in
                        ContrastFindingRow(finding: finding) { model.fixContrast(finding) }
                    }
                }
            }
            // Up to seven rows; keep Back/Apply on screen in the fixed-size sheet.
            .frame(maxHeight: 140)
            Text("You can still apply this theme as it is.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var applyingStep: some View {
        VStack(spacing: 12) {
            switch model.applyResult {
            case .none:
                ProgressView("Applying…")
            case .success:
                Label("Theme applied.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Done") { onDone() }
            case .failure(let error):
                Label("Couldn't apply that theme: \(String(describing: error))", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }
}

/// One readability finding: the pairing as it renders now, what's affected, and — when a
/// readable colour exists — a preview of the fix beside its Fix button.
private struct ContrastFindingRow: View {
    let finding: DesignTokenContrastFinding
    let onFix: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ContrastSample(foreground: finding.foreground, background: finding.background)
            Image(systemName: finding.severity == .error ? "exclamationmark.triangle.fill" : "exclamationmark.circle")
                .foregroundStyle(finding.severity == .error ? Color.orange : Color.secondary)
                .accessibilityHidden(true)
            message.font(.callout)
            Spacer()
            if let fixed = fixedColors {
                Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityHidden(true)
                ContrastSample(foreground: fixed.foreground, background: fixed.background)
                Button("Fix", action: onFix)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The pairing's colours after the fix: the suggestion replaces whichever side the fix adjusts
    /// (the foreground, or the primary fill for button labels).
    private var fixedColors: (foreground: String, background: String)? {
        guard let suggested = finding.suggestedValue else { return nil }
        return finding.pair.adjustedToken == finding.pair.foregroundToken
            ? (suggested, finding.background)
            : (finding.foreground, suggested)
    }

    /// One whole sentence per place and severity, so each translates as a unit. Warnings only
    /// occur for links and button labels.
    @ViewBuilder
    private var message: some View {
        switch (finding.pair.place, finding.severity) {
        case (.bodyText, _): Text("Body text will be hard to read")
        case (.secondaryText, _): Text("Secondary text will be hard to read")
        case (.cardText, _): Text("Text on cards will be hard to read")
        case (.cardSecondaryText, _): Text("Secondary text on cards will be hard to read")
        case (.links, .error): Text("Links will be hard to read")
        case (.links, .warning): Text("Links may be hard to read at small sizes")
        case (.buttonLabels, .error): Text("Button labels will be hard to read")
        case (.buttonLabels, .warning): Text("Button labels may be hard to read at small sizes")
        case (.cardLinks, .error): Text("Links on cards will be hard to read")
        case (.cardLinks, .warning): Text("Links on cards may be hard to read at small sizes")
        }
    }
}

/// "Aa" drawn in a pairing's colours — the owner judges readability by eye, not by ratio.
private struct ContrastSample: View {
    let foreground: String
    let background: String

    var body: some View {
        Text(verbatim: "Aa")
            .font(.callout.bold())
            .foregroundStyle(Color(hex: foreground))
            .frame(width: 36, height: 24)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(hex: background)))
            .accessibilityHidden(true)
    }
}

/// One selectable built-in theme card — owns its own hover state so each `ForEach` item tracks
/// the mouse independently rather than sharing one flag across the grid (#677).
private struct ThemeApplyCard: View {
    let theme: Theme
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isHoverActive: Bool { isHovering && controlActiveState != .inactive && !isSelected }

    private var fillColor: Color {
        if isSelected { return Color.accentColor.opacity(0.15) }
        if isHoverActive { return Color.accentColor.opacity(0.08) }
        return Color.gray.opacity(0.08)
    }

    private var strokeColor: Color {
        if isSelected { return Color.accentColor }
        if isHoverActive { return Color.accentColor.opacity(0.4) }
        return Color.clear
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    ForEach(theme.swatch, id: \.self) { hex in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(hex: hex))
                            .frame(width: 24, height: 24)
                    }
                }
                Text(theme.name)
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                Text(theme.blurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(fillColor))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(strokeColor, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: isHoverActive)
    }
}
