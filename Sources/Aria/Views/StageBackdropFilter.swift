import CoreImage

/// The shared look of the "blurred cover" backdrop on both platforms.
///
/// A plain Gaussian blur of a dark cover leaves large near-black regions that
/// read as holes behind the white player text. The look therefore does three
/// things after the blur: lifts the shadows, keeps the highlights in check,
/// and lowers the overall contrast. The result is an even, gently tinted wash
/// rather than a high-contrast copy of the sleeve.
///
/// Both `MacPlaybackStage` and `PhoneStageBackdrop` call `texture(from:)`, so
/// macOS and iOS can never drift apart again.
enum StageBackdropFilter {
    /// The texture is rendered once into a small bitmap and scaled up.
    static let side: CGFloat = 128

    /// Dimming layer drawn over the texture by the views. With the shadows
    /// lifted, a light scrim is enough — the old 0.42 was pushing the darker
    /// parts of the sleeve into solid black.
    static let scrim: Double = 0.30

    /// Centred square → small bitmap → blur → shadow/contrast shaping.
    /// The result is cropped to `(0, 0, side, side)`.
    static func texture(from image: CIImage) -> CIImage {
        let extent = image.extent
        let square = min(extent.width, extent.height)
        guard square > 0 else { return image }

        let crop = CGRect(x: extent.midX - square / 2,
                          y: extent.midY - square / 2,
                          width: square, height: square)
        let small = image
            .cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: side / square, y: side / square))
        let rect = CGRect(x: 0, y: 0, width: side, height: side)

        return small
            .clampedToExtent()
            // SPlayer's `filter: blur(45px) saturate(1.2)` applied to a
            // 1.5x-scaled cover: on this 128px texture a large radius is what
            // actually dissolves the dark shapes instead of leaving them as
            // recognisable, near-black blobs behind the text.
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 18])
            // CSS blur mixes shadowed pixels with their bright neighbours for
            // free. CIGaussianBlur does not, so lift the shadows explicitly and
            // hold the highlights back — this is what stops any area reading
            // as a hole in the background.
            .applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputShadowAmount": 0.6,
                "inputHighlightAmount": 0.79
            ])
            // Saturation goes UP (1.2), not down: a desaturated wash is what
            // makes dark covers look muddy rather than warm.
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.2,
                kCIInputBrightnessKey: 0.0,
                kCIInputContrastKey: 0.66
            ])
            .cropped(to: rect)
    }
}
