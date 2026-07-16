import Foundation
import CoreGraphics
import ImageIO

public enum ImageLoaderError: Error {
    case unsupportedFormat(String)
    case decodeFailed(String)
}

public enum ImageLoader {
    public static let fitsExtensions: Set<String> = ["fit", "fits", "fts"]
    public static let bitmapExtensions: Set<String> = ["png", "jpg", "jpeg", "tif", "tiff"]

    /// Load an image, optionally verifying `expectedIdentity` (review5 item 1). When an identity
    /// is supplied the file is opened ONCE, that descriptor's fstat is compared against the
    /// identity the watcher validated, the bytes are read from that same descriptor (with a
    /// content-digest re-check), and the image is DECODED FROM THOSE BYTES — never a fresh
    /// path-open. A replaced/truncated file throws `FileIdentityMismatchError`; callers skip the
    /// frame with an honest log. `expectedIdentity == nil` is the legacy path-based behavior,
    /// unchanged.
    public static func load(url: URL, expectedIdentity: FileIdentity? = nil) throws -> AstroImage {
        let ext = url.pathExtension.lowercased()
        if fitsExtensions.contains(ext) {
            let data: Data
            if expectedIdentity != nil {
                data = try FileIdentity.read(url: url, verifying: expectedIdentity)
            } else {
                data = try Data(contentsOf: url, options: .alwaysMapped)
            }
            let fits = try FITSReader.read(data)
            return AstroImage(width: fits.width, height: fits.height, channels: fits.channels,
                              pixels: fits.pixels, sourceIsLinear: true)
        }
        if bitmapExtensions.contains(ext) {
            if expectedIdentity != nil {
                let data = try FileIdentity.read(url: url, verifying: expectedIdentity)
                guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
                    throw ImageLoaderError.decodeFailed("cannot open \(url.lastPathComponent)")
                }
                return try decodeBitmap(source: src, name: url.lastPathComponent)
            }
            return try loadBitmap(url: url)
        }
        throw ImageLoaderError.unsupportedFormat(ext)
    }

    private static func loadBitmap(url: URL) throws -> AstroImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageLoaderError.decodeFailed("cannot open \(url.lastPathComponent)")
        }
        return try decodeBitmap(source: src, name: url.lastPathComponent)
    }

    private static func decodeBitmap(source src: CGImageSource, name: String) throws -> AstroImage {
        // Thumbnail-with-transform applies EXIF orientation; max dimension huge = full size.
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 20_000,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw ImageLoaderError.decodeFailed("cannot decode \(name)")
        }
        let w = cg.width, h = cg.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ImageLoaderError.decodeFailed("context")
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let plane = w * h
        var px = [Float](repeating: 0, count: plane * 3)
        for p in 0..<plane {
            px[p]             = Float(rgba[p * 4])     / 255.0
            px[plane + p]     = Float(rgba[p * 4 + 1]) / 255.0
            px[2 * plane + p] = Float(rgba[p * 4 + 2]) / 255.0
        }
        return AstroImage(width: w, height: h, channels: 3, pixels: px, sourceIsLinear: false)
    }
}
