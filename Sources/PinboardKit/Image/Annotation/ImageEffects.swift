import AppKit
import CoreImage

/// Lazily produced blurred / pixellated copies of a base image, shared by the
/// on-screen canvas and the exporter so both look identical.
final class ImageEffects {
    private let base: CGImage
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private var blurredCache: CGImage?
    private var mosaicCache: CGImage?

    init(base: CGImage) {
        self.base = base
    }

    var blurred: CGImage? {
        if let blurredCache { return blurredCache }
        let input = CIImage(cgImage: base)
        let radius = max(8, min(CGFloat(base.width), CGFloat(base.height)) / 45)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: input.extent),
              let result = context.createCGImage(output, from: input.extent) else { return nil }
        blurredCache = result
        return result
    }

    var mosaic: CGImage? {
        if let mosaicCache { return mosaicCache }
        let input = CIImage(cgImage: base)
        let scale = max(8, min(CGFloat(base.width), CGFloat(base.height)) / 40)
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(CIVector(x: input.extent.midX, y: input.extent.midY), forKey: kCIInputCenterKey)
        guard let output = filter.outputImage?.cropped(to: input.extent),
              let result = context.createCGImage(output, from: input.extent) else { return nil }
        mosaicCache = result
        return result
    }
}
