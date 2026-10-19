import CoreGraphics
import Testing

@Suite("右键系统事件还原")
@MainActor
struct RightPressEventReplayTests {
    @Test func shortClickDownUsesCurrentTapAndKeepsOriginalMouseData() throws {
        let event = try #require(CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown,
            mouseCursorPosition: CGPoint(x: 120, y: 240), mouseButton: .right))
        event.timestamp = 123_456_789
        event.setIntegerValueField(.mouseEventClickState, value: 2)
        let proxy = try #require(OpaquePointer(bitPattern: 1))
        var delivered: [RightPressEventReplay.Destination] = []
        let restored = RightPressEventReplay.restore(event, proxy: proxy, sourcePID: 12, frontmostPID: 12, sameWindow: true) { posted, route in
            delivered.append(route)
            #expect(posted.type == .rightMouseDown)
            #expect(posted.location == CGPoint(x: 120, y: 240))
            #expect(posted.timestamp == 123_456_789)
            #expect(posted.getIntegerValueField(.mouseEventClickState) == 2)
            #expect(RightPressEventReplay.isReplay(posted))
        }
        #expect(restored)
        #expect(delivered == [.tap(proxy)])
    }

    @Test func shutdownFallbackUsesSystemSessionInsteadOfPostingToAProcess() throws {
        let event = try #require(CGEvent(source: nil))
        var delivered: [RightPressEventReplay.Destination] = []
        #expect(RightPressEventReplay.restore(event, proxy: nil, sourcePID: 12, frontmostPID: 12, sameWindow: true) { _, route in
            delivered.append(route)
        })
        #expect(delivered == [.session])
    }

    @Test func focusChangeDiscardsSuppressedDownInsteadOfSendingToNewApp() throws {
        let event = try #require(CGEvent(source: nil))
        var count = 0
        #expect(!RightPressEventReplay.restore(event, proxy: nil, sourcePID: 12, frontmostPID: 99, sameWindow: true) { _, _ in count += 1 })
        #expect(count == 0)
    }

    @Test func overlayWindowCannotReceiveTheRestoredRightClick() throws {
        let event = try #require(CGEvent(source: nil))
        var count = 0
        #expect(!RightPressEventReplay.restore(event, proxy: nil, sourcePID: 12, frontmostPID: 12, sameWindow: false) { _, _ in count += 1 })
        #expect(count == 0)
    }
}
