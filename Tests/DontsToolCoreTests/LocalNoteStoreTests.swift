import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import DontsToolCore

@Suite("本地便笺存储") @MainActor
struct LocalNoteStoreTests {
    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalNotesTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func content(_ text: String, image: String? = nil) -> LocalNoteContent {
        var nodes: [[String: Any]] = [["type": "paragraph", "content": [["type": "text", "text": text]]]]
        if let image { nodes.append(["type": "image", "attrs": ["src": image]]) }
        let data = try! JSONSerialization.data(withJSONObject: ["type": "doc", "content": nodes])
        return LocalNoteContent(json: String(decoding: data, as: UTF8.self), markdown: image.map { "\(text)\n\n![](\($0))" } ?? text, plainText: text)
    }

    private func png(width: Int = 2, height: Int = 2) throws -> Data {
        let bytes = [UInt8](repeating: 120, count: width * height)
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func restartPreservesContentAutomaticTitleAndManualMetadata() throws {
        try withRoot { root in
            let store = LocalNoteStore(rootURL: root)
            let created = try store.create()
            let body = content("\n 第一行标题\n第二行")
            let saved = try store.updateContent(created.id, content: body)
            #expect(saved.title == "第一行标题")
            #expect(saved.titleIsAutomatic)
            _ = try store.rename(created.id, title: " 手动标题 ")
            _ = try store.setPinned(created.id, pinned: true)
            let restarted = LocalNoteStore(rootURL: root)
            let record = try #require(restarted.note(created.id))
            #expect(record.content == body)
            #expect(record.title == "手动标题")
            #expect(record.isPinned)
            #expect(!record.titleIsAutomatic)
            _ = try restarted.updateContent(record.id, content: content("changed"))
            #expect(restarted.note(record.id)?.title == "手动标题")
            _ = try restarted.rename(record.id, title: "  ")
            #expect(restarted.note(record.id)?.title == "changed")
            #expect(restarted.note(record.id)?.titleIsAutomatic == true)
            #expect(restarted.search("changed", limit: 1).map(\.id) == [record.id])
        }
    }

    @Test func invalidSnapshotAndFailedWritePreservePriorRecord() throws {
        try withRoot { root in
            let store = LocalNoteStore(rootURL: root)
            let note = try store.create(title: "原名")
            _ = try store.updateContent(note.id, content: content("saved"))
            let file = root.appendingPathComponent(note.id.uuidString).appendingPathComponent("note.json")
            let before = try Data(contentsOf: file)
            let invalid = LocalNoteContent(json: "{\"type\":\"paragraph\"}", markdown: "bad", plainText: "bad")
            #expect(throws: (any Error).self) { try store.updateContent(note.id, content: invalid) }
            #expect(try Data(contentsOf: file) == before)
            #expect(store.note(note.id)?.content.plainText == "saved")
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            #expect(throws: (any Error).self) { try store.rename(note.id, title: "must fail") }
            #expect(store.note(note.id)?.title == "原名")
        }
    }

    @Test func corruptAndFutureRecordsStayUntouchedAndReportLoadError() throws {
        try withRoot { root in
            let store = LocalNoteStore(rootURL: root)
            let first = try store.create()
            let second = try store.create()
            let firstURL = root.appendingPathComponent(first.id.uuidString).appendingPathComponent("note.json")
            let secondURL = root.appendingPathComponent(second.id.uuidString).appendingPathComponent("note.json")
            let corrupt = Data("not json".utf8)
            try corrupt.write(to: firstURL)
            var future = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: secondURL)) as? [String: Any])
            future["schemaVersion"] = 999
            let futureData = try JSONSerialization.data(withJSONObject: future)
            try futureData.write(to: secondURL)
            let restarted = LocalNoteStore(rootURL: root)
            #expect(restarted.notes.isEmpty)
            #expect(restarted.loadError != nil)
            #expect(try Data(contentsOf: firstURL) == corrupt)
            #expect(try Data(contentsOf: secondURL) == futureData)
        }
    }

    @Test func trashRestoreMovesOwnedContentAndBlocksStaleSaves() throws {
        try withRoot { root in
            let store = LocalNoteStore(rootURL: root)
            let note = try store.create()
            let asset = try store.importImage(png(), for: note.id)
            let body = content("body", image: asset.relativePath)
            _ = try store.updateContent(note.id, content: body)
            try store.trash(note.id)
            #expect(store.note(note.id) == nil)
            #expect(store.trashedNotes.map(\.id) == [note.id])
            #expect(throws: (any Error).self) { try store.updateContent(note.id, content: content("stale")) }
            let restarted = LocalNoteStore(rootURL: root)
            _ = try restarted.restore(note.id)
            #expect(restarted.note(note.id)?.content == body)
            #expect(try Data(contentsOf: restarted.assetURL(for: note.id, relativePath: asset.relativePath)) == png())
        }
    }

    @Test func importedImageSurvivesOriginalRemovalAndCrossNoteCopy() throws {
        try withRoot { root in
            let store = LocalNoteStore(rootURL: root)
            let a = try store.create()
            let b = try store.create()
            let source = root.appendingPathComponent("misleading-name.exe")
            let image = try png()
            try image.write(to: source)
            let asset = try store.importImageFile(source, for: a.id)
            #expect(asset.mimeType == "image/png")
            #expect(asset.relativePath.hasSuffix(".png"))
            try FileManager.default.removeItem(at: source)
            let copy = try store.copyImage(from: a.id, relativePath: asset.relativePath, to: b.id)
            #expect(copy.relativePath != asset.relativePath)
            #expect(try Data(contentsOf: store.assetURL(for: b.id, relativePath: copy.relativePath)) == image)
            try store.trash(a.id)
            #expect(try Data(contentsOf: store.assetURL(for: b.id, relativePath: copy.relativePath)) == image)
        }
    }

    @Test func pathsSymlinksAndExternalImagesAreRejected() throws {
        try withRoot { root in
            let store = LocalNoteStore(rootURL: root)
            let note = try store.create()
            let asset = try store.importImage(png(), for: note.id)
            for path in ["../note.json", "/etc/passwd", "assets/../../note.json", "https://a/image.png", "assets/a.png"] {
                #expect(throws: (any Error).self) { try store.assetURL(for: note.id, relativePath: path) }
                #expect(throws: (any Error).self) { try store.updateContent(note.id, content: content("bad", image: path)) }
            }
            let owned = try store.assetURL(for: note.id, relativePath: asset.relativePath)
            let outside = root.appendingPathComponent("outside.png")
            try png().write(to: outside)
            try FileManager.default.removeItem(at: owned)
            try FileManager.default.createSymbolicLink(at: owned, withDestinationURL: outside)
            #expect(throws: (any Error).self) { try store.assetURL(for: note.id, relativePath: asset.relativePath) }
            #expect(throws: (any Error).self) { try store.importImageFile(owned, for: note.id) }
            let directory = root.appendingPathComponent(note.id.uuidString)
            let moved = root.appendingPathComponent("moved")
            try FileManager.default.moveItem(at: directory, to: moved)
            try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: moved)
            #expect(throws: (any Error).self) { try store.rename(note.id, title: "escape") }
            let reopened = LocalNoteStore(rootURL: root)
            #expect(reopened.note(note.id) == nil)
            #expect(reopened.loadError != nil)
        }
    }

    @Test func invalidAndOversizeImageFilesDoNotCreateAssets() throws {
        try withRoot { root in
            let store = LocalNoteStore(rootURL: root)
            let note = try store.create()
            #expect(throws: (any Error).self) { try store.importImage(Data("fake png".utf8), for: note.id) }
            #expect(throws: (any Error).self) { try store.importImage(Data(repeating: 0, count: 21 * 1024 * 1024), for: note.id) }
            let sparse = root.appendingPathComponent("huge.png")
            _ = FileManager.default.createFile(atPath: sparse.path, contents: nil)
            let handle = try FileHandle(forWritingTo: sparse)
            try handle.truncate(atOffset: 21 * 1024 * 1024)
            try handle.close()
            #expect(throws: (any Error).self) { try store.importImageFile(sparse, for: note.id) }
            #expect(throws: (any Error).self) { try store.importImageFile(root, for: note.id) }
        }
    }

    @Test func pixelBombAndTruncatedImageAreRejectedBeforeImport() throws {
        try withRoot { root in
            let store = LocalNoteStore(rootURL: root)
            let note = try store.create()
            let original = try png()
            #expect(throws: (any Error).self) { try store.importImage(Data(original.prefix(40)), for: note.id) }
            let oversized = try png(width: 6000, height: 6000)
            do {
                _ = try store.importImage(oversized, for: note.id)
                Issue.record("Oversized image was imported")
            } catch LocalNoteError.imageTooLarge {
                // The header limit must reject this before decoding its pixel data.
            } catch {
                Issue.record("Expected imageTooLarge, got \(error)")
            }
        }
    }

    @Test func symlinkedAssetDirectoryAndRecordCannotEscapeTheStore() throws {
        try withRoot { root in
            let store = LocalNoteStore(rootURL: root)
            let note = try store.create()
            let asset = try store.importImage(png(), for: note.id)
            let directory = root.appendingPathComponent(note.id.uuidString)
            let assets = directory.appendingPathComponent("assets")
            let movedAssets = root.appendingPathComponent("outside-assets")
            try FileManager.default.moveItem(at: assets, to: movedAssets)
            try FileManager.default.createSymbolicLink(at: assets, withDestinationURL: movedAssets)
            #expect(throws: (any Error).self) { try store.assetURL(for: note.id, relativePath: asset.relativePath) }
            #expect(throws: (any Error).self) { try store.importImage(png(), for: note.id) }
            let recordURL = directory.appendingPathComponent("note.json")
            let outsideRecord = root.appendingPathComponent("outside-note.json")
            let original = try Data(contentsOf: recordURL)
            try FileManager.default.moveItem(at: recordURL, to: outsideRecord)
            try FileManager.default.createSymbolicLink(at: recordURL, withDestinationURL: outsideRecord)
            #expect(throws: (any Error).self) { try store.setPinned(note.id, pinned: true) }
            #expect(store.note(note.id)?.isPinned == false)
            #expect(try Data(contentsOf: outsideRecord) == original)
        }
    }

    @Test func oversizedAndDeepSnapshotsDoNotReplaceSavedBody() throws {
        try withRoot { root in
            let store = LocalNoteStore(rootURL: root)
            let note = try store.create()
            _ = try store.updateContent(note.id, content: content("saved"))
            let huge = LocalNoteContent(json: LocalNoteContent.empty.json, markdown: String(repeating: "x", count: 4 * 1024 * 1024 + 1), plainText: "bad")
            #expect(throws: (any Error).self) { try store.updateContent(note.id, content: huge) }
            let nested = String(repeating: "[", count: 70) + "0" + String(repeating: "]", count: 70)
            let deep = LocalNoteContent(json: "{\"type\":\"doc\",\"content\":\(nested)}", markdown: "bad", plainText: "bad")
            #expect(throws: (any Error).self) { try store.updateContent(note.id, content: deep) }
            #expect(LocalNoteStore(rootURL: root).note(note.id)?.content.plainText == "saved")
        }
    }

    @Test func exportUsesCurrentSnapshotAndCopiesOnlyReferencedImages() throws {
        try withRoot { root in
            let store = LocalNoteStore(rootURL: root)
            let note = try store.create()
            let first = try store.importImage(png(), for: note.id)
            let unused = try store.importImage(png(), for: note.id)
            _ = try store.updateContent(note.id, content: content("saved", image: unused.relativePath))
            let current = content("current", image: first.relativePath)
            let export = root.appendingPathComponent("export")
            #expect(try store.exportMarkdown(note.id, content: current, to: export) == export)
            #expect(try String(contentsOf: export.appendingPathComponent("note.md"), encoding: .utf8) == current.markdown)
            #expect(FileManager.default.fileExists(atPath: export.appendingPathComponent(first.relativePath).path))
            #expect(!FileManager.default.fileExists(atPath: export.appendingPathComponent(unused.relativePath).path))
            #expect(try Data(contentsOf: store.assetURL(for: note.id, relativePath: unused.relativePath)) == png())
            #expect(store.note(note.id)?.content.plainText == "saved")
            #expect(throws: (any Error).self) { try store.exportMarkdown(note.id, to: export) }
        }
    }

    @Test func plainTextAndAppendingPreserveValidProseMirrorStructureAndImages() throws {
        try withRoot { root in
            let store = LocalNoteStore(rootURL: root)
            let created = try store.create(title: "工作日志")
            let asset = try store.importImage(png(), for: created.id)
            let base = content("初始段落", image: asset.relativePath)
            _ = try store.updateContent(created.id, content: base)

            let single = base.appending(entry: "补充一行", timestamp: "09:15")
            let multi = single.appending(entry: "第一行\n\n第三行", timestamp: "10:30")
            let saved = try store.updateContent(created.id, content: multi)
            #expect(saved.content.plainText.contains("[09:15] 补充一行"))
            #expect(saved.content.plainText.contains("[10:30]\n第一行\n\n第三行"))
            #expect(saved.content.json.contains(asset.relativePath))

            let standalone = LocalNoteContent.plainText("首行\r\n\r\n尾行")
            let createdFromText = try store.create(content: standalone)
            #expect(createdFromText.title == "首行")
            #expect(createdFromText.titleIsAutomatic)
            #expect(createdFromText.content.plainText == "首行\n\n尾行")
        }
    }

    @Test func quickCaptureAppendsToSameDayNoteAndRotatesAcrossDaysAndPermanentDelete() throws {
        try withRoot { root in
            let store = LocalNoteStore(rootURL: root)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
            let day1Morning = calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 9, minute: 5))!
            let day1Afternoon = calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 14, minute: 30))!
            let day2 = calendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 8, minute: 0))!

            let first = try store.appendQuickCapture("排查 Redis 超时", now: day1Morning, calendar: calendar)
            #expect(first.title == "速记 · 2026-11-18")
            #expect(!first.titleIsAutomatic)
            #expect(first.content.plainText == "[09:05] 排查 Redis 超时")

            let second = try store.appendQuickCapture("确认连接池上限", now: day1Afternoon, calendar: calendar)
            #expect(second.id == first.id)
            #expect(second.content.plainText == "[09:05] 排查 Redis 超时\n\n[14:30] 确认连接池上限")

            let nextDay = try store.appendQuickCapture("次日待办", now: day2, calendar: calendar)
            #expect(nextDay.id != first.id)
            #expect(nextDay.title == "速记 · 2026-11-19")
            #expect(store.notes.count == 2)

            try store.trash(first.id)
            #expect(store.trashedNotes.map(\.id) == [first.id])
            try store.deletePermanently(first.id)
            #expect(store.trashedNotes.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Trash").appendingPathComponent(first.id.uuidString).path))
        }
    }
}
