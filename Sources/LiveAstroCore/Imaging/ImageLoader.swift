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

    public static func load(url: URL) throws -> AstroImage {
        let ext = url.pathExtension.lowercased()
        if fitsExtensions.contains(ext) {
            let fits = try FITSReader.read(try Data(contentsOf: url, options: .alwaysMapped))
            return AstroImage(width: fits.width, height: fits.height, channels: fits.channels,
                              pixels: fits.pixels, sourceIsLinear: true)
        }
        if bitmapExtensions.contains(ext) { return try loadBitmap(url: url) }
        throw ImageLoaderError.unsupportedFormat(ext)
    }

    private static func loadBitmap(url: URL) throws -> AstroImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageLoaderError.decodeFailed("cannot open \(url.lastPathComponent)")
        }
        // Thumbnail-with-transform applies EXIF orientation; max dimension huge = full size.
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 20_000,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw ImageLoaderError.decodeFailed("cannot decode \(url.lastPathComponent)")
        }
        let w = cg.width, h = cg.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let space = cg.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
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
