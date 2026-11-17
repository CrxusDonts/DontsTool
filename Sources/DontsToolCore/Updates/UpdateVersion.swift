import Foundation

public enum UpdateVersion {
    /// Only released MAJOR.MINOR.PATCH versions are eligible, independently of CI build numbers.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let next = components(candidate), let installed = components(current) else { return false }
        return installed.lexicographicallyPrecedes(next)
    }

    private static func components(_ value: String) -> [Int]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var result: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  part.count == 1 || part.first != "0", let number = Int(part) else { return nil }
            result.append(number)
        }
        return result
    }
}
