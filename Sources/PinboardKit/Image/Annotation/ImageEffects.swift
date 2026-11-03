import AppKit
import CryptoKit

/// Produces irreversible mosaic and secure-blur images from a base bitmap,
/// shared by the on-screen canvas and the exporter so both look identical.
///
/// Unlike naive `CIPixellate` or `CIGaussianBlur` (which preserve invertible
/// per-block pixel averages or linear convolutions), both effects first
/// coarsely quantize each cell and permute/blend across a multi-cell
/// neighborhood using `SHA256`. `mosaic` keeps the crisp uniform tiles;
/// `secureBlur` smooths across the scrambled tiles so the result looks like a
/// soft blur while discarding sub-block stroke density and glyph geometry.
final class ImageEffects {
    private let base: CGImage
    private var mosaicCache: [Int: CGImage] = [:]
    private var blurCache: [Int: CGImage] = [:]

    init(base: CGImage) {
        self.base = base
    }

    var mosaic: CGImage? {
        mosaic(blockSize: nil)
    }

    var blurred: CGImage? {
        secureBlur(radius: nil)
    }

    func mosaic(blockSize: Int? = nil) -> CGImage? {
        let size = resolvedBlockSize(blockSize)
        guard size > 0 else { return nil }
        if let cached = mosaicCache[size] { return cached }
        guard var buffer = scrambledBuffer(cellSize: size),
              let image = makeImage(from: &buffer.pixels, width: buffer.width, height: buffer.height) else {
            return nil
        }
        mosaicCache[size] = image
        return image
    }

    func secureBlur(radius: Int? = nil) -> CGImage? {
        let size = resolvedBlockSize(radius)
        guard size > 0 else { return nil }
        if let cached = blurCache[size] { return cached }
        guard var buffer = scrambledBuffer(cellSize: size) else { return nil }
        let blurRadius = max(4, size * 2 / 3)
        smoothBoxBlur(&buffer.pixels, width: buffer.width, height: buffer.height, radius: blurRadius)
        guard let image = makeImage(from: &buffer.pixels, width: buffer.width, height: buffer.height) else {
            return nil
        }
        blurCache[size] = image
        return image
    }

    private func resolvedBlockSize(_ requested: Int?) -> Int {
        let width = base.width
        let height = base.height
        guard width > 0, height > 0 else { return 0 }
        let defaultSize = max(12, min(width, height) / 32)
        return max(8, min(max(width, height), requested ?? defaultSize))
    }

    private func scrambledBuffer(cellSize size: Int) -> (pixels: [UInt8], width: Int, height: Int)? {
        let width = base.width
        let height = base.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))

        let cols = (width + size - 1) / size
        let rows = (height + size - 1) / size
        let step = 48
        func quantize(_ value: Int) -> UInt8 {
            UInt8(clamping: ((value + step / 2) / step) * step)
        }

        var quantizedGrid = [UInt8](repeating: 0, count: cols * rows * 3)
        for cy in 0..<rows {
            let yStart = cy * size
            let yEnd = min(yStart + size, height)
            for cx in 0..<cols {
                let xStart = cx * size
                let xEnd = min(xStart + size, width)
                var rSum = 0, gSum = 0, bSum = 0, count = 0
                for y in yStart..<yEnd {
                    let rowOffset = y * bytesPerRow
                    for x in xStart..<xEnd {
                        let offset = rowOffset + x * 4
                        rSum += Int(pixels[offset])
                        gSum += Int(pixels[offset + 1])
                        bSum += Int(pixels[offset + 2])
                        count += 1
                    }
                }
                let idx = (cy * cols + cx) * 3
                if count > 0 {
                    quantizedGrid[idx] = quantize(rSum / count)
                    quantizedGrid[idx + 1] = quantize(gSum / count)
                    quantizedGrid[idx + 2] = quantize(bSum / count)
                }
            }
        }

        let seedDigest = Array(SHA256.hash(data: Data(quantizedGrid)))
        for cy in 0..<rows {
            let yStart = cy * size
            let yEnd = min(yStart + size, height)
            let minY = max(0, cy - 2)
            let maxY = min(rows - 1, cy + 2)
            for cx in 0..<cols {
                let xStart = cx * size
                let xEnd = min(xStart + size, width)
                let minX = max(0, cx - 2)
                let maxX = min(cols - 1, cx + 2)

                var neighbors: [(r: Int, g: Int, b: Int)] = []
                neighbors.reserveCapacity(25)
                var sumR = 0, sumG = 0, sumB = 0
                var minR = 255, maxR = 0, minG = 255, maxG = 0, minB = 255, maxB = 0
                for ny in minY...maxY {
                    for nx in minX...maxX {
                        let idx = (ny * cols + nx) * 3
                        let r = Int(quantizedGrid[idx])
                        let g = Int(quantizedGrid[idx + 1])
                        let b = Int(quantizedGrid[idx + 2])
                        neighbors.append((r, g, b))
                        sumR += r; sumG += g; sumB += b
                        minR = min(minR, r); maxR = max(maxR, r)
                        minG = min(minG, g); maxG = max(maxG, g)
                        minB = min(minB, b); maxB = max(maxB, b)
                    }
                }

                var hasher = SHA256()
                hasher.update(data: Data(seedDigest))
                let coords = [UInt32(cx).littleEndian, UInt32(cy).littleEndian, UInt32(size).littleEndian]
                coords.withUnsafeBytes { hasher.update(bufferPointer: $0) }
                let digest = Array(hasher.finalize())

                let nCount = neighbors.count
                let avgR = sumR / nCount
                let avgG = sumG / nCount
                let avgB = sumB / nCount
                let picked = neighbors[Int(digest[0]) % nCount]
                let weight = 96 + (Int(digest[1]) % 65)
                var r = (avgR * weight + picked.r * (256 - weight)) / 256
                var g = (avgG * weight + picked.g * (256 - weight)) / 256
                var b = (avgB * weight + picked.b * (256 - weight)) / 256

                let hasContrast = (maxR - minR) + (maxG - minG) + (maxB - minB) > 0
                if hasContrast {
                    r += (Int(digest[2]) % 33) - 16
                    g += (Int(digest[3]) % 33) - 16
                    b += (Int(digest[4]) % 33) - 16
                }

                let tileR = UInt8(clamping: r)
                let tileG = UInt8(clamping: g)
                let tileB = UInt8(clamping: b)
                for y in yStart..<yEnd {
                    let rowOffset = y * bytesPerRow
                    for x in xStart..<xEnd {
                        let offset = rowOffset + x * 4
                        pixels[offset] = tileR
                        pixels[offset + 1] = tileG
                        pixels[offset + 2] = tileB
                        pixels[offset + 3] = 255
                    }
                }
            }
        }
        return (pixels, width, height)
    }

    private func smoothBoxBlur(_ pixels: inout [UInt8], width: Int, height: Int, radius: Int) {
        guard radius > 1, width > 1, height > 1 else { return }
        let bytesPerRow = width * 4
        var temp = pixels
        let r = min(radius, min(width - 1, height - 1))
        for _ in 0..<2 {
            // Horizontal pass
            for y in 0..<height {
                let rowOffset = y * bytesPerRow
                for x in 0..<width {
                    let x0 = max(0, x - r)
                    let x1 = min(width - 1, x + r)
                    let count = x1 - x0 + 1
                    var sumR = 0, sumG = 0, sumB = 0
                    for sx in x0...x1 {
                        let off = rowOffset + sx * 4
                        sumR += Int(pixels[off])
                        sumG += Int(pixels[off + 1])
                        sumB += Int(pixels[off + 2])
                    }
                    let dst = rowOffset + x * 4
                    temp[dst] = UInt8(sumR / count)
                    temp[dst + 1] = UInt8(sumG / count)
                    temp[dst + 2] = UInt8(sumB / count)
                    temp[dst + 3] = 255
                }
            }
            // Vertical pass
            for x in 0..<width {
                let colOffset = x * 4
                for y in 0..<height {
                    let y0 = max(0, y - r)
                    let y1 = min(height - 1, y + r)
                    let count = y1 - y0 + 1
                    var sumR = 0, sumG = 0, sumB = 0
                    for sy in y0...y1 {
                        let off = sy * bytesPerRow + colOffset
                        sumR += Int(temp[off])
                        sumG += Int(temp[off + 1])
                        sumB += Int(temp[off + 2])
                    }
                    let dst = y * bytesPerRow + colOffset
                    pixels[dst] = UInt8(sumR / count)
                    pixels[dst + 1] = UInt8(sumG / count)
                    pixels[dst + 2] = UInt8(sumB / count)
                    pixels[dst + 3] = 255
                }
            }
        }
    }

    private func makeImage(from pixels: inout [UInt8], width: Int, height: Int) -> CGImage? {
        let bytesPerRow = width * 4
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        return context.makeImage()
    }
}
