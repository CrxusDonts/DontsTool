import AppKit
import Testing

@Suite("Copy selected text", .serialized)
@MainActor
struct SelectedTextReaderTests {
    @Test func hoveringAnotherWindowOfTheSameAppCannotCopyTheFocusedWindowsText() async {
        let fixture = CopyFixture()
        fixture.focusMatchesSource = false
        let reading = await fixture.reader().read(pid: 42, at: .zero)
        #expect(reading.text == nil)
        #expect(fixture.copyRequests == 0)
        #expect(fixture.text == "existing clipboard")
    }

    @Test func clipboardChangesDuringAsyncWindowValidationDiscardTheCapturedText() async {
        let fixture = CopyFixture()
        fixture.onFocus = {
            if fixture.focusChecks == 4 { fixture.text = "a newer copy"; fixture.count += 1 }
        }
        let reading = await fixture.reader().read(pid: 42, at: .zero)
        #expect(reading.text == nil)
        #expect(fixture.text == "a newer copy")
    }

    @Test func directCopyReadsOnlyNewClipboardContentWithoutClearingIt() async {
        let fixture = CopyFixture()
        let reading = await fixture.reader().read(pid: 42, at: .zero)
        #expect(reading.text == "command")
        #expect(fixture.copyRequests == 1)
        #expect(fixture.clipboardAtCopy == "existing clipboard")
        #expect(fixture.text == "command")
    }

    @Test func unsuccessfulCopyNeverUsesOrClearsTheOldClipboard() async {
        let fixture = CopyFixture()
        fixture.copiesText = false
        let reading = await fixture.reader().read(pid: 42, at: .zero)
        #expect(reading.text == nil)
        #expect(fixture.text == "existing clipboard")
        #expect(fixture.clipboardReads == 0)
    }

    @Test func identicalTextStillRequiresAFreshCopy() async {
        let fixture = CopyFixture()
        fixture.text = "command"
        let reading = await fixture.reader().read(pid: 42, at: .zero)
        #expect(reading.text == "command")
        #expect(fixture.count == 2)
    }

    @Test func sourceChangeOrPasswordFieldDoesNotSendCopy() async {
        for secure in [false, true] {
            let fixture = CopyFixture()
            fixture.secure = secure
            if !secure { fixture.frontmost = 99 }
            let reading = await fixture.reader().read(pid: 42, at: .zero)
            #expect(reading.text == nil)
            #expect(fixture.copyRequests == 0)
            #expect(fixture.text == "existing clipboard")
        }
    }

    @Test func changedWindowDuringCopyCannotReturnUnrelatedClipboardText() async {
        let fixture = CopyFixture()
        fixture.copiesText = false
        fixture.onPause = { fixture.window = 9; fixture.text = "other window"; fixture.count += 1 }
        let reading = await fixture.reader().read(pid: 42, at: .zero)
        #expect(reading.text == nil)
        #expect(fixture.text == "other window")
    }

    @Test func delayedCopyWaitsForTextInsteadOfUsingOldData() async {
        let fixture = CopyFixture()
        fixture.copiesText = false
        fixture.onPause = {
            fixture.pauses += 1
            if fixture.pauses == 3 { fixture.text = "delayed selection"; fixture.count += 1 }
        }
        let reading = await fixture.reader().read(pid: 42, at: .zero)
        #expect(reading.text == "delayed selection")
    }

    @Test func oversizedSelectionDoesNotReachTranslation() async {
        let fixture = CopyFixture()
        fixture.copyResult = String(repeating: "a", count: 8001)
        let reading = await fixture.reader().read(pid: 42, at: .zero)
        #expect(reading.text == nil)
        #expect(reading.diagnostic.contains("8000"))
    }

    @Test func postingFailureDoesNotReadExistingClipboard() async {
        let fixture = CopyFixture()
        fixture.postSucceeds = false
        let reading = await fixture.reader().read(pid: 42, at: .zero)
        #expect(reading.text == nil)
        #expect(fixture.clipboardReads == 0)
        #expect(fixture.text == "existing clipboard")
    }
}

@MainActor
private final class CopyFixture {
    var frontmost: pid_t? = 42
    var window: CGWindowID? = 7
    var focusChecks = 0
    var onFocus: (() -> Void)?
    var focusMatchesSource = true
    var secure = false
    var postSucceeds = true
    var copiesText = true
    var copyResult = "command"
    var copyRequests = 0
    var clipboardAtCopy: String?
    var count = 1
    var text: String? = "existing clipboard"
    var clipboardReads = 0
    var pauses = 0
    var onPause: (() -> Void)?
    func reader() -> SelectedTextReader {
        SelectedTextReader(environment: .init(frontmostPID: { self.frontmost },
            window: { _, _ in self.window }, sourceIsFocused: { _, _ in self.focusChecks += 1; self.onFocus?(); return self.focusMatchesSource }, secureInput: { _ in self.secure },
            postCopy: { pid in
                #expect(pid == 42)
                self.copyRequests += 1; self.clipboardAtCopy = self.text
                if !self.postSucceeds { return false }
                if self.copiesText { self.text = self.copyResult; self.count += 1 }
                return true
            }, changeCount: { self.count }, copiedText: { self.clipboardReads += 1; return self.text },
            pause: { self.onPause?(); await Task.yield() }))
    }
}
