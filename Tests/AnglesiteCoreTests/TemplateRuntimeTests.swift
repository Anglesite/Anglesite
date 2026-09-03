import Testing
import Foundation
@testable import AnglesiteCore
import AnglesiteTestSupport

final class TemplateRuntimeTests {
    private let tempDir: URL
    private let scratch = TemporaryUserDefaults()
    private var defaults: UserDefaults { scratch.defaults }
    private let fileManager = FileManager.default

    init() throws {
        tempDir = fileManager.temporaryDirectory.appendingPathComponent("anglesite-template-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    deinit {
        try? fileManager.removeItem(at: tempDir)
        scratch.cleanup()
    }

    @Test("Is template directory recognizes themes.ts") func isTemplateDirectoryRecognizesThemes() throws {
        let template = tempDir.appendingPathComponent("Template", isDirectory: true)
        let scriptsDir = template.appendingPathComponent("scripts", isDirectory: true)
        try fileManager.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        try Data("export const THEMES".utf8).write(to: scriptsDir.appendingPathComponent("themes.ts"))

        #expect(TemplateRuntime.isTemplateDirectory(template))
    }

    @Test("Is template directory rejects bare directory") func isTemplateDirectoryRejectsBareDirectory() {
        #expect(!TemplateRuntime.isTemplateDirectory(tempDir))
    }

    @Test("Resolve reports missing when no source found") func resolveReportsMissingWhenNoSourceFound() {
        let settings = AppSettings(defaults: defaults)
        let resolution = TemplateRuntime.resolve(settings: settings)
        #expect(resolution.source == .missing)
        #expect(resolution.url == nil)
    }

    @Test("Resolve honors override when valid") func resolveHonorsOverrideWhenValid() throws {
        let template = tempDir.appendingPathComponent("Template", isDirectory: true)
        let scriptsDir = template.appendingPathComponent("scripts", isDirectory: true)
        try fileManager.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        try Data("export const THEMES".utf8).write(to: scriptsDir.appendingPathComponent("themes.ts"))

        let settings = AppSettings(defaults: defaults)
        settings.templatePathOverride = template

        let resolution = TemplateRuntime.resolve(settings: settings)
        #expect(resolution.source == .override(template))
        #expect(resolution.url?.path == template.path)
    }

    @Test("Resolve ignores invalid override") func resolveIgnoresInvalidOverride() {
        let settings = AppSettings(defaults: defaults)
        settings.templatePathOverride = tempDir
        let resolution = TemplateRuntime.resolve(settings: settings)
        #expect(resolution.source == .missing)
    }
}
