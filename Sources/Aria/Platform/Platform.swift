import SwiftUI

#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

extension Image {
    /// `Image(nsImage:)` / `Image(uiImage:)` behind one name.
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

extension PlatformImage {
    /// Decodes image data, returning nil rather than an empty image.
    static func decode(_ data: Data) -> PlatformImage? {
        PlatformImage(data: data)
    }

    /// The backing bitmap, for pixel work.
    var cgImageRef: CGImage? {
        #if os(macOS)
        return cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        return cgImage
        #endif
    }

    /// A copy whose longest side is at most `maxSide` points. The lock screen
    /// keeps its own copy of whatever artwork it is handed, so a 3000px sleeve
    /// would otherwise be carried around for the rest of the session.
    ///
    /// Call this on the main thread: both backends draw through AppKit/UIKit.
    func scaled(maxSide: CGFloat) -> PlatformImage {
        let size = self.size
        let longest = max(size.width, size.height)
        guard longest > maxSide, longest > 0, let source = cgImageRef else { return self }
        let factor = maxSide / longest
        let target = CGSize(width: (size.width * factor).rounded(),
                            height: (size.height * factor).rounded())
        #if os(macOS)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: Int(target.width),
                                   pixelsHigh: Int(target.height),
                                   bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep else { return self }
        rep.size = target
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            context.cgContext.draw(source, in: CGRect(origin: .zero, size: target))
            NSGraphicsContext.restoreGraphicsState()
        }
        let out = NSImage(size: target)
        out.addRepresentation(rep)
        return out
        #else
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { context in
            context.cgContext.draw(source, in: CGRect(origin: .zero, size: target))
        }
        #endif
    }
}

// MARK: - System integration

enum Platform {
    /// Shows the file in Finder. No equivalent on iOS, where the sandbox is the
    /// whole world — callers hide the action instead.
    static var canRevealInFileManager: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    static func reveal(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
    }

    static func copyToPasteboard(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }

    /// Whether the user may point the library somewhere else. On iOS the
    /// library is always the app's Documents folder, filled over File Sharing.
    static var supportsFolderPicker: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// Asks for a folder, calling back with the chosen path. macOS only.
    static func chooseFolder(startingAt path: String, _ completion: (String) -> Void) {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: path)
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            completion(url.path)
        }
        #endif
    }
}
