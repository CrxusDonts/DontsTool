import Foundation

@MainActor
public protocol LocalNoteOpening: AnyObject {
    func createNote()
    func openNote(_ id: UUID)
}
