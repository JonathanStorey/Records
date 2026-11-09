/// Fractional index keys that order the targets of a to-many reference.
///
/// A key is a string of base-62 digits, `0-9A-Za-z`, that never ends in `0`. Keys compare byte
/// by byte, and there is always a key between any two, so moving or inserting one target
/// rewrites only that target's link.
enum OrderKey {
    private static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)
    private static let base = digits.count

    /// Whether `key` is a well-formed key.
    static func isValid(_ key: String) -> Bool {
        guard let last = key.utf8.last, last != digits[0] else { return false }
        return key.utf8.allSatisfy(digits.contains)
    }

    /// Whether `a` sorts before `b`, byte by byte.
    static func precedes(_ a: String, _ b: String) -> Bool {
        a.utf8.lexicographicallyPrecedes(b.utf8)
    }

    /// A key after `lower` and before `upper`. `nil` means no bound. `lower` must precede `upper`.
    static func between(_ lower: String?, _ upper: String?) -> String {
        let a = (lower ?? "").utf8.map(digit)
        let b = upper.map { $0.utf8.map(digit) }
        return String(decoding: midpoint(a, b).map { digits[$0] }, as: UTF8.self)
    }

    /// Order keys for targets in their current order, given each target's loaded key, if any.
    ///
    /// Keeps the largest set of loaded keys that already sort in the current order, and gives
    /// every other target a new key between its kept neighbors. Appending, removing, or moving
    /// one target changes only that target's key.
    static func assign(_ loaded: [String?]) -> [String] {
        let usable = loaded.map { key in key.flatMap { isValid($0) ? $0 : nil } }
        let kept = Set(longestIncreasingRun(usable))

        var result = [String](repeating: "", count: loaded.count)
        var index = 0
        var lower: String?
        while index < loaded.count {
            if kept.contains(index), let key = usable[index] {
                result[index] = key
                lower = key
                index += 1
                continue
            }
            // A run of targets that need keys, up to the next kept key.
            var end = index
            while end < loaded.count, !kept.contains(end) { end += 1 }
            let upper = end < loaded.count ? usable[end] : nil
            for position in index..<end {
                let key = between(lower, upper)
                result[position] = key
                lower = key
            }
            index = end
        }
        return result
    }

    /// The positions of the longest strictly increasing run of keys, skipping `nil`s.
    private static func longestIncreasingRun(_ keys: [String?]) -> [Int] {
        var tails: [Int] = [] // tails[k]: position ending the best run of length k + 1
        var previous = [Int?](repeating: nil, count: keys.count)
        for (position, key) in keys.enumerated() {
            guard let key else { continue }
            var low = 0, high = tails.count
            while low < high {
                let mid = (low + high) / 2
                if precedes(keys[tails[mid]]!, key) { low = mid + 1 } else { high = mid }
            }
            previous[position] = low > 0 ? tails[low - 1] : nil
            if low == tails.count { tails.append(position) } else { tails[low] = position }
        }
        var run: [Int] = []
        var position = tails.last
        while let current = position {
            run.append(current)
            position = previous[current]
        }
        return run.reversed()
    }

    private static func digit(_ byte: UInt8) -> Int {
        digits.firstIndex(of: byte) ?? 0
    }

    /// Digits strictly between `a` and `b`, where `b == nil` means no upper bound. Neither may
    /// end in `0`, and `a` must sort before `b`.
    private static func midpoint(_ a: [Int], _ b: [Int]?) -> [Int] {
        if let b {
            // Skip the shared prefix, treating missing digits of `a` as 0.
            var shared = 0
            while shared < b.count, (shared < a.count ? a[shared] : 0) == b[shared] { shared += 1 }
            if shared > 0 {
                return Array(b[..<shared]) + midpoint(Array(a.dropFirst(shared)), Array(b.dropFirst(shared)))
            }
        }
        let digitA = a.first ?? 0
        let digitB = b?.first ?? base
        if digitB - digitA > 1 {
            return [(digitA + digitB) / 2]
        }
        if let b, b.count > 1 {
            return [b[0]]
        }
        return [digitA] + midpoint(Array(a.dropFirst()), nil)
    }
}
