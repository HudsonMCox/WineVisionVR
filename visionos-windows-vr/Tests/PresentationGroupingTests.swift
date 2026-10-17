import Foundation

@main
struct PresentationGroupingTests {
    static func main() {
        let metadata = WindowsVRStereoPair(first: UInt32(1888), second: UInt32(1792))
        precondition(metadata.count == 2 && Array(metadata) == [1888, 1792])
        precondition(metadata.allSatisfy { $0 > 0 } && Array(metadata.reversed()) == [1792, 1888])
        let optionalSources = WindowsVRStereoPair<Int?>(first: nil, second: 42)
        precondition(optionalSources[0] == nil && optionalSources[1] == 42)
        precondition(!optionalSources.allSatisfy { $0 != nil })
        // Same rule as the previous array/filter implementation: compare each
        // pending attachment to the first one and preserve original eye order.
        for count in 0...2 {
            for relation in 0..<16 {
                var old = Array(0..<count)
                var pending = (UInt(1) << count) - 1
                while let first = old.first {
                    let matches: (Int, Int) -> Bool = { a, b in
                        a == b || (relation & (1 << (a * 2 + b))) != 0
                    }
                    let group = old.filter { matches(first, $0) }
                    let actual = WindowsVRPresentationGroups.next(remaining: pending, count: count, matches: matches)
                    let expected = group.reduce(UInt(0)) { $0 | (1 << $1) }
                    precondition(actual == expected)
                    old.removeAll { group.contains($0) }
                    pending &= ~actual
                }
                precondition(pending == 0)
            }
        }
        precondition(WindowsVRPresentationGroups.next(remaining: 0, count: 0) { _, _ in true } == 0)
        print("PASS: all mono/stereo grouping relations, distinct attachments, shared layered targets and original eye ordering")
    }
}
