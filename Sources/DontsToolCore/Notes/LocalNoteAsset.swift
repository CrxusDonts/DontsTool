import Foundation

public struct LocalNoteAsset: Equatable, Sendable {
    public let relativePath: String
    public let mimeType: String

    public init(relativePath: String, mimeType: String) {
        self.relativePath = relativePath
        self.mimeType = mimeType
    }
}
