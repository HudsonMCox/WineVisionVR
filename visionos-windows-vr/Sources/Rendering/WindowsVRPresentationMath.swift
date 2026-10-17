import simd

/// ABI tuples are packed column-major floats. Load by value without a temporary
/// Array, including when the imported C tuple has only Float alignment.
enum WindowsVRPresentationMath {
    static func matrix<T>(from value: T) -> simd_float4x4 {
        precondition(MemoryLayout<T>.size == MemoryLayout<simd_float4x4>.size)
        return withUnsafeBytes(of: value) { $0.loadUnaligned(as: simd_float4x4.self) }
    }

    static func equal(_ a: simd_float4x4, _ b: simd_float4x4) -> Bool {
        a.columns.0 == b.columns.0 && a.columns.1 == b.columns.1 &&
        a.columns.2 == b.columns.2 && a.columns.3 == b.columns.3
    }
}

struct WindowsVRProjectionCache {
    private(set) var projection = matrix_identity_float4x4
    private(set) var inverse = matrix_identity_float4x4

    mutating func update(_ value: simd_float4x4) {
        guard !WindowsVRPresentationMath.equal(projection, value) else { return }
        projection = value
        inverse = value.inverse
    }
}

/// These transforms depend on the guest render pose, not each display refresh.
/// Owned snapshots keep this value alongside the exact pixels it describes.
struct WindowsVRRenderPose {
    let eyeFromOrigin: (simd_float4x4, simd_float4x4)
    let projections: (simd_float4x4, simd_float4x4)

    init(head: simd_float4x4, eyes: (simd_float4x4, simd_float4x4),
         projections: (simd_float4x4, simd_float4x4)) {
        eyeFromOrigin = ((head * eyes.0).inverse, (head * eyes.1).inverse)
        self.projections = projections
    }

    func reproject(eye: Int, originFromCurrentEye: simd_float4x4,
                   currentProjectionInverse: simd_float4x4) -> simd_float4x4 {
        var rotation = (eye == 0 ? eyeFromOrigin.0 : eyeFromOrigin.1) * originFromCurrentEye
        rotation.columns.3 = SIMD4<Float>(0, 0, 0, 1)
        return (eye == 0 ? projections.0 : projections.1) * rotation * currentProjectionInverse
    }
}

/// Fixed stereo grouping, with no temporary index/filter arrays. Groups preserve
/// the first pending eye's order and the renderer's exact attachment identity rule.
enum WindowsVRPresentationGroups {
    static func next(remaining: UInt, count: Int, matches: (Int, Int) -> Bool) -> UInt {
        precondition(count >= 0 && count <= 2)
        guard remaining != 0 else { return 0 }
        let first = remaining.trailingZeroBitCount
        precondition(first < count)
        var group: UInt = 1 << first
        for index in (first + 1)..<count where remaining & (1 << index) != 0 {
            if matches(first, index) { group |= 1 << index }
        }
        return group
    }
}

/// The ABI always carries exactly two eyes. Keep their temporary metadata and
/// source references inline instead of allocating short-lived Array buffers.
struct WindowsVRStereoPair<Element>: RandomAccessCollection {
    let first: Element
    let second: Element
    var startIndex: Int { 0 }
    var endIndex: Int { 2 }
    func index(after index: Int) -> Int { index + 1 }
    func index(before index: Int) -> Int { index - 1 }
    subscript(index: Int) -> Element {
        precondition(index == 0 || index == 1)
        return index == 0 ? first : second
    }
}
