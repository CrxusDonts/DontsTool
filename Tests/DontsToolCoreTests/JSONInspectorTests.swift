import Foundation
import Testing
@testable import DontsToolCore

@Suite("JSON 结构检查与格式化对比")
struct JSONInspectorTests {
    @Test func analyzesValidObjectBreadcrumbsAndFiltering() throws {
        let source = """
        {
          "appName": "DontsTool",
          "settings": {
            "a.b": {
              "tabSize": 2
            }
          },
          "tools": [
            { "name": "json" },
            { "name": "notes" }
          ],
          "active": true,
          "extra": null
        }
        """

        let analysis = JSONInspector.analyze(source)
        guard case .valid(let rootKind, let rootCount, let nodeCount, let lineCount) = analysis.validation else {
            Issue.record("Expected valid analysis, got \(analysis.validation)")
            return
        }
        #expect(rootKind == .object)
        #expect(rootCount == 5)
        #expect(nodeCount > 5)
        #expect(lineCount == 14)
        #expect(analysis.validation.badgeText.contains("有效 JSON"))

        let tabOffset = (source as NSString).range(of: "2").location
        let breadcrumb = analysis.breadcrumb(atUTF16Offset: tabOffset)
        #expect(breadcrumb.map(\.label) == ["$", "settings", "a.b", "tabSize"])
        #expect(breadcrumb.last?.id == "$.settings[\"a.b\"].tabSize")

        let node = analysis.node(atUTF16Offset: tabOffset)
        #expect(node?.kind == .number)
        #expect(node?.preview == "2")

        let arrayOffset = (source as NSString).range(of: "\"notes\"").location
        let arrayBreadcrumb = analysis.breadcrumb(atUTF16Offset: arrayOffset)
        #expect(arrayBreadcrumb.map(\.label) == ["$", "tools", "[1]", "name"])
        #expect(arrayBreadcrumb.last?.id == "$.tools[1].name")

        let filtered = try #require(analysis.filteredRoot(matching: "notes"))
        #expect(filtered.children.map(\.key) == ["tools"])
        #expect(filtered.children[0].children.map(\.key) == ["[1]"])
        #expect(filtered.children[0].children[0].children.map(\.key) == ["name"])
    }

    @Test func analyzesEmptyAndInvalidInputs() {
        let empty = JSONInspector.analyze("   \n\t ")
        #expect(empty.validation == .empty)
        #expect(empty.root == nil)
        #expect(empty.validation.badgeText == "等待输入 JSON")

        let invalid = JSONInspector.analyze("{\n  \"a\": 1,\n  \"a\": 2\n}")
        if case .invalid(let message, let line, let column, _) = invalid.validation {
            #expect(line == 3)
            #expect(column == 3)
            #expect(message.contains("重复"))
        } else {
            Issue.record("Expected invalid summary")
        }
        #expect(invalid.root == nil)
    }

    @Test @MainActor func formatComparisonBothFormatsValidSidesInOneUndoAndReportsErrors() throws {
        let store = ToolDocumentStore()
        let document = store.create(ToolOpenRequest(kind: .json, input: "{}"))
        document.session.comparing = true
        document.session.compareLeft = #"{"b":2,"a":1}"#
        document.session.compareRight = #"{"c":[1,2]}"#
        let editor = ToolDraftEditor(document: document)

        let changed = try editor.formatComparisonBoth()
        #expect(changed)
        #expect(document.session.compareLeft.contains("\n  \"b\": 2"))
        #expect(document.session.compareRight.contains("\n  \"c\": ["))

        editor.undoManager.undo()
        #expect(document.session.compareLeft == #"{"b":2,"a":1}"#)
        #expect(document.session.compareRight == #"{"c":[1,2]}"#)

        document.session.compareRight = "{broken"
        #expect(throws: JSONSideIssue.self) {
            _ = try editor.formatComparisonBoth()
        }
        #expect(document.session.errorSide == "右侧")
        #expect(document.session.errorMessage?.contains("右侧") == true)
    }
}
