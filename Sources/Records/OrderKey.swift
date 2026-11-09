/// Fractional index keys that order the targets of a to-many reference.
///
/// A key is an integer part followed by an optional fraction, in base-62 digits `0-9A-Za-z`. The
/// integer part's first character gives its length: `a` through `z` start positive integers of 1
/// to 26 digits, and `Z` down to `A` start negative ones. So `a0` is zero, `a1` follows it, and
/// `b10` follows `az`. The fraction never ends in `0`.
///
/// Keys compare byte by byte, and there is always a key between any two, so moving or inserting
/// one target rewrites only that target's link. Appending or prepending steps the integer part,
/// so a list built one append at a time keeps keys of a few characters. Only repeated inserts
/// into the same gap lengthen the fraction, by about one character per six inserts.
enum OrderKey {
    private static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)
    private static let base = digits.count
    private static let zero: [UInt8] = Array("a0".utf8)
    /// The smallest integer part, which has nothing before it, so it isn't a valid key.
    private static let smallest: [UInt8] = Array("A".utf8) + [UInt8](repeating: digits[0], count: 26)

    /// Whether `key` is a well-formed key.
    static func isValid(_ key: String) -> Bool {
        isValid(Array(key.utf8))
    }

    /// Whether `a` sorts before `b`, byte by byte.
    static func precedes(_ a: String, _ b: String) -> Bool {
        a.utf8.lexicographicallyPrecedes(b.utf8)
    }

    /// A key after `lower` and before `upper`. `nil` means no bound. Both must be valid, and
    /// `lower` must precede `upper`.
    static func between(_ lower: String?, _ upper: String?) -> String {
        string(between(lower.map { Array($0.utf8) }, upper.map { Array($0.utf8) }))
    }

    /// `count` keys in order after `lower` and before `upper`, spread across the gap rather than
    /// each squeezed after the last.
    static func between(_ lower: String?, _ upper: String?, count: Int) -> [String] {
        keys(between: lower.map { Array($0.utf8) }, upper.map { Array($0.utf8) }, count: count).map(string)
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
            for (position, key) in zip(index..<end, between(lower, upper, count: end - index)) {
                result[position] = key
            }
            lower = result[end - 1]
            index = end
        }
        return result
    }

    // MARK: - Keys as bytes

    private static func string(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    private static func isValid(_ key: [UInt8]) -> Bool {
        guard key != smallest, let integer = integerPart(of: key),
              key.allSatisfy(digits.contains)
        else { return false }
        return key.count == integer.count || key.last != digits[0]
    }

    /// The number of characters in an integer part that starts with `head`, including the head.
    private static func integerLength(_ head: UInt8) -> Int? {
        switch head {
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return Int(head - UInt8(ascii: "a")) + 2
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): return Int(UInt8(ascii: "Z") - head) + 2
        default: return nil
        }
    }

    private static func integerPart(of key: [UInt8]) -> [UInt8]? {
        guard let head = key.first, let length = integerLength(head), length <= key.count else { return nil }
        return Array(key[..<length])
    }

    private static func precedes(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        a.lexicographicallyPrecedes(b)
    }

    private static func between(_ a: [UInt8]?, _ b: [UInt8]?) -> [UInt8] {
        guard let a else {
            guard let b, let integer = integerPart(of: b) else { return zero }
            let fraction = Array(b[integer.count...])
            if integer == smallest { return integer + midpoint([], fraction) }
            // `b` has a fraction, so its integer part alone comes before it.
            if integer.count < b.count { return integer }
            return decrement(integer) ?? integer + midpoint([], fraction)
        }
        guard let integerA = integerPart(of: a) else { return zero }
        let fractionA = Array(a[integerA.count...])
        guard let b, let integerB = integerPart(of: b) else {
            return increment(integerA) ?? integerA + midpoint(fractionA, nil)
        }
        if integerA == integerB {
            return integerA + midpoint(fractionA, Array(b[integerB.count...]))
        }
        if let next = increment(integerA), precedes(next, b) {
            return next
        }
        return integerA + midpoint(fractionA, nil)
    }

    private static func keys(between a: [UInt8]?, _ b: [UInt8]?, count: Int) -> [[UInt8]] {
        guard count > 0 else { return [] }
        if count == 1 { return [between(a, b)] }
        if b == nil {
            // Appending: step forward from `a`.
            var result = [between(a, nil)]
            while result.count < count { result.append(between(result.last, nil)) }
            return result
        }
        if a == nil {
            // Prepending: step back from `b`.
            var result = [between(nil, b)]
            while result.count < count { result.append(between(nil, result.last)) }
            return result.reversed()
        }
        // Between two keys: split the gap in half each time, so the keys stay short.
        let middle = count / 2
        let key = between(a, b)
        return keys(between: a, key, count: middle) + [key] + keys(between: key, b, count: count - middle - 1)
    }

    /// The integer part after `integer`, or `nil` past the largest.
    private static func increment(_ integer: [UInt8]) -> [UInt8]? {
        let head = integer[0]
        var digitsPart = integer.dropFirst().map(digit)
        var position = digitsPart.count - 1
        while position >= 0 {
            if digitsPart[position] + 1 < base {
                digitsPart[position] += 1
                return [head] + digitsPart.map { digits[$0] }
            }
            digitsPart[position] = 0
            position -= 1
        }
        // Every digit carried, so the integer needs a different length.
        if head == UInt8(ascii: "Z") { return zero }
        if head == UInt8(ascii: "z") { return nil }
        let next = head + 1
        if next > UInt8(ascii: "a") {
            digitsPart.append(0)
        } else {
            digitsPart.removeLast()
        }
        return [next] + digitsPart.map { digits[$0] }
    }

    /// The integer part before `integer`, or `nil` before the smallest.
    private static func decrement(_ integer: [UInt8]) -> [UInt8]? {
        let head = integer[0]
        var digitsPart = integer.dropFirst().map(digit)
        var position = digitsPart.count - 1
        while position >= 0 {
            if digitsPart[position] > 0 {
                digitsPart[position] -= 1
                return [head] + digitsPart.map { digits[$0] }
            }
            digitsPart[position] = base - 1
            position -= 1
        }
        // Every digit borrowed, so the integer needs a different length.
        if head == UInt8(ascii: "a") { return Array("Z".utf8) + [digits[base - 1]] }
        if head == UInt8(ascii: "A") { return nil }
        let previous = head - 1
        if previous < UInt8(ascii: "Z") {
            digitsPart.append(base - 1)
        } else {
            digitsPart.removeLast()
        }
        return [previous] + digitsPart.map { digits[$0] }
    }

    /// Fraction digits strictly between `a` and `b`, where `b == nil` means no upper bound.
    /// Neither may end in `0`, and `a` must sort before `b`.
    private static func midpoint(_ a: [UInt8], _ b: [UInt8]?) -> [UInt8] {
        if let b {
            // Skip the shared prefix, treating missing digits of `a` as 0.
            var shared = 0
            while shared < b.count, (shared < a.count ? a[shared] : digits[0]) == b[shared] { shared += 1 }
            if shared > 0 {
                return Array(b[..<shared]) + midpoint(Array(a.dropFirst(shared)), Array(b.dropFirst(shared)))
            }
        }
        let digitA = a.first.map(digit) ?? 0
        let digitB = b?.first.map(digit) ?? base
        if digitB - digitA > 1 {
            return [digits[(digitA + digitB) / 2]]
        }
        if let b, b.count > 1 {
            return [b[0]]
        }
        return [digits[digitA]] + midpoint(Array(a.dropFirst()), nil)
    }

    private static func digit(_ byte: UInt8) -> Int {
        digits.firstIndex(of: byte) ?? 0
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
}
