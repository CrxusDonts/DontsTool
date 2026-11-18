import Foundation

@MainActor
public protocol LocalNoteOpening: AnyObject {
    func createNote()
    func createNote(with text: String)
    @discardableResult func quickCapture(_ text: String) throws -> LocalNoteRecord
    func openNote(_ id: UUID)
}

public extension LocalNoteOpening {
    func createNote(with text: String) { createNote() }
    @discardableResult func quickCapture(_ text: String) throws -> LocalNoteRecord {
        throw LocalNoteError.invalidContent
    }
}
