import Foundation
import simd

@main
struct PresentationMathTests {
    static func close(_ a: simd_float4x4, _ b: simd_float4x4) {
        for column in 0..<4 {
            for row in 0..<4 {
                precondition(abs(a[column][row]-b[column][row]) < 0.0001)
            }
        }
    }
    static func pose(_ angle: Float, _ position: SIMD3<Float>) -> simd_float4x4 {
        var result=simd_float4x4(simd_quatf(angle: angle, axis: simd_normalize(SIMD3<Float>(1,2,3))))
        result.columns.3=SIMD4<Float>(position,1)
        return result
    }
    static func main() {
        var cache=WindowsVRProjectionCache()
        for n in 0..<100 {
            // Perspective matrices include off-axis eyes and a reversed-Z plane.
            var p=matrix_identity_float4x4
            p.columns.0.x=1.1+Float(n)*0.001; p.columns.1.y=1.3
            p.columns.2=SIMD4<Float>(0.12,-0.08,0.0001,-1)
            p.columns.3=SIMD4<Float>(0,0,0.1,0)
            cache.update(p);close(cache.inverse,p.inverse)
            cache.update(p);close(cache.inverse,p.inverse)
            let head=pose(Float(n)*0.01,SIMD3<Float>(1,2,3))
            let eyes=(pose(0,SIMD3<Float>(-0.032,0,0)),pose(0,SIMD3<Float>(0.032,0,0)))
            let cached=WindowsVRRenderPose(head:head,eyes:eyes,projections:(p,p))
            for frame in 0..<90 {
                let current=pose(Float(frame)*0.01,SIMD3<Float>(4,5,6))
                for eye in 0..<2 {
                    let eyeTransform=eye==0 ? eyes.0 : eyes.1
                    var reference=(head*eyeTransform).inverse*(current*eyeTransform)
                    reference.columns.3=SIMD4<Float>(0,0,0,1)
                    close(cached.reproject(eye:eye,originFromCurrentEye:current*eyeTransform,currentProjectionInverse:cache.inverse),p*reference*p.inverse)
                }
            }
            let tuple=(p[0][0],p[0][1],p[0][2],p[0][3],p[1][0],p[1][1],p[1][2],p[1][3],p[2][0],p[2][1],p[2][2],p[2][3],p[3][0],p[3][1],p[3][2],p[3][3])
            close(WindowsVRPresentationMath.matrix(from:tuple),p)
        }
        print("PASS: 18000 eye reprojections match the previous formula, changing/asymmetric projections and packed Float ABI tuples")
    }
}
