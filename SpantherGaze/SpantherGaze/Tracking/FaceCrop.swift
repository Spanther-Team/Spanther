import ARKit
import CoreVideo
import UIKit

/// The face cut out of ARKit's camera image for Vision (architecture proposal, "Tracking loop"): ARKit's eyes are
/// projected into the captured image, a square round them is copied into a buffer of our own pool, and the ARFrame
/// can be let go at once (held frames stall ARKit). Vision then works on a small image with the face filling it,
/// instead of the whole sensor frame. Tracking queue only.
final class FaceCropper {
    private var pools: [Int: CVPixelBufferPool] = [:]
    private var poolFormat: OSType = 0

    /// The face's square in the captured image: sensor pixels, the image's own orientation (rows top down), centred
    /// between the eyes and 2.6 eye distances across (a little more than the face), its side a multiple of 64 so a
    /// few pools serve every distance, kept inside the image. Nil when the eyes do not project into the image.
    static func faceRect(frame: ARFrame, face: ARFaceAnchor) -> CGRect? {
        let res = frame.camera.imageResolution
        guard res.width >= 64, res.height >= 64 else { return nil }
        let left = imagePoint(eye: face.leftEyeTransform, face: face, frame: frame)
        let right = imagePoint(eye: face.rightEyeTransform, face: face, frame: frame)
        guard left.x.isFinite, left.y.isFinite, right.x.isFinite, right.y.isFinite else { return nil }
        let centre = CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2)
        guard centre.x > 0, centre.y > 0, centre.x < res.width, centre.y < res.height else { return nil }
        let eyes = hypot(left.x - right.x, left.y - right.y)
        let limit = Int(min(res.width, res.height)) / 64 * 64
        guard limit >= 128 else { return nil }
        let side = CGFloat(min(limit, max(128, Int((eyes * 2.6 / 64).rounded(.up)) * 64)))
        // Even corners: the colour plane has half the resolution.
        let x = Int(max(0, min(res.width - side, centre.x - side / 2))) / 2 * 2
        let y = Int(max(0, min(res.height - side, centre.y - side / 2))) / 2 * 2
        return CGRect(x: CGFloat(x), y: CGFloat(y), width: side, height: side)
    }

    /// An eye's centre (face-local transform) in captured-image pixels. projectPoint gives the point in a viewport
    /// that shows the camera image the way the screen would (mirrored for the front camera); the inverse of the frame's
    /// display transform takes it back to the image's own normalised coordinates (origin top left), whatever the
    /// mirroring and rotation are.
    private static func imagePoint(eye: simd_float4x4, face: ARFaceAnchor, frame: ARFrame) -> CGPoint {
        let res = frame.camera.imageResolution
        let world = face.transform * eye
        let p3 = simd_float3(world.columns.3.x, world.columns.3.y, world.columns.3.z)
        let p = frame.camera.projectPoint(p3, orientation: .landscapeRight, viewportSize: res)
        let toImage = frame.displayTransform(for: .landscapeRight, viewportSize: res).inverted()
        let n = CGPoint(x: p.x / res.width, y: p.y / res.height).applying(toImage)
        return CGPoint(x: n.x * res.width, y: n.y * res.height)
    }

    /// Copies `rect` (from `faceRect`) of a bi-planar 4:2:0 image into a buffer of our own pool, the same format.
    func crop(_ source: CVPixelBuffer, rect: CGRect) -> CVPixelBuffer? {
        let format = CVPixelBufferGetPixelFormatType(source)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(source) == 2 else { return nil }
        let side = Int(rect.width)
        let x0 = Int(rect.minX), y0 = Int(rect.minY)
        guard side >= 64, x0 >= 0, y0 >= 0,
              x0 + side <= CVPixelBufferGetWidth(source), y0 + side <= CVPixelBufferGetHeight(source),
              let pool = pool(side: side, format: format) else { return nil }
        var made: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess, let out = made else { return nil }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(out, [])
        defer {
            CVPixelBufferUnlockBaseAddress(out, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        for plane in 0..<2 {
            guard let from = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                  let to = CVPixelBufferGetBaseAddressOfPlane(out, plane) else { return nil }
            let fromStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
            let toStride = CVPixelBufferGetBytesPerRowOfPlane(out, plane)
            // Plane 0 is luma, one byte a pixel; plane 1 is interleaved Cb Cr at half the resolution, two bytes.
            let sub = plane == 0 ? 1 : 2
            let bytes = plane == 0 ? 1 : 2
            let rows = side / sub
            let rowBytes = side / sub * bytes
            let start = (x0 / sub) * bytes
            for r in 0..<rows {
                memcpy(to + r * toStride, from + (y0 / sub + r) * fromStride + start, rowBytes)
            }
        }
        return out
    }

    private func pool(side: Int, format: OSType) -> CVPixelBufferPool? {
        if format != poolFormat {
            pools.removeAll()
            poolFormat = format
        }
        if let p = pools[side] { return p }
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferWidthKey as String: side,
            kCVPixelBufferHeightKey as String: side,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        let poolAttributes: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: 3]
        var made: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, poolAttributes as CFDictionary, attributes as CFDictionary, &made)
        if let made { pools[side] = made }
        return made
    }
}
