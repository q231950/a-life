#if !canImport(simd)
// Linux has no simd module, so the few of its functions the tests use are
// written out here, for the vectors HorizonPlan works in.

func simd_dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    (a * b).sum()
}

func simd_cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}

func simd_length(_ a: SIMD3<Float>) -> Float {
    simd_dot(a, a).squareRoot()
}

func simd_normalize(_ a: SIMD3<Float>) -> SIMD3<Float> {
    a / simd_length(a)
}

func simd_distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    simd_length(a - b)
}
#endif
