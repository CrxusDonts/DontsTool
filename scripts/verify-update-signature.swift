import CryptoKit
import Foundation

// Public-key verification is independent of the CI signing tool and never needs a private key.
do {
    guard CommandLine.arguments.count == 4,
          let publicData = Data(base64Encoded: CommandLine.arguments[1]), publicData.count == 32,
          let signature = Data(base64Encoded: CommandLine.arguments[2]), signature.count == 64 else {
        throw NSError(domain: "UpdateSignature", code: 1)
    }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicData)
    let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]), options: .mappedIfSafe)
    guard key.isValidSignature(signature, for: archive) else {
        throw NSError(domain: "UpdateSignature", code: 2)
    }
} catch {
    FileHandle.standardError.write(Data("Update signature verification failed.\n".utf8))
    exit(1)
}
