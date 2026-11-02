import CoreGraphics
import Foundation
import Libass

/// libass wrapped for the apps: feed it the ASS file (fonts embedded by the server), ask for the picture at a time.
/// libass is not thread-safe, so every call runs on one serial queue.
final class AssRenderer: @unchecked Sendable {
    enum Result { case unchanged, image(CGImage?) }

    private let queue = DispatchQueue(label: "animeroll.libass", qos: .userInteractive)
    private var library: OpaquePointer?
    private var renderer: OpaquePointer?
    private var track: UnsafeMutablePointer<ASS_Track>?
    private var frame = (w: 0, h: 0)

    /// nil when libass can't read the data.
    init?(data: Data) {
        guard let lib = ass_library_init() else { return nil }
        library = lib
        ass_set_message_cb(lib, { _, _, _, _ in }, nil)
        guard let r = ass_renderer_init(lib) else { ass_library_done(lib); return nil }
        renderer = r
        // System fonts through CoreText; embedded ones come from the file's [Fonts] section.
        ass_set_fonts(r, nil, "Helvetica", Int32(ASS_FONTPROVIDER_AUTODETECT.rawValue), nil, 1)
        var bytes = [CChar](repeating: 0, count: data.count)
        data.withUnsafeBytes { raw in bytes.withUnsafeMutableBytes { $0.copyMemory(from: raw) } }
        let parsed = bytes.withUnsafeMutableBufferPointer { ass_read_memory(lib, $0.baseAddress, data.count, nil) }
        guard let parsed else { ass_renderer_done(r); ass_library_done(lib); return nil }
        track = parsed
    }

    deinit {
        let (t, r, l) = (track, renderer, library)
        queue.sync {
            if let t { ass_free_track(t) }
            if let r { ass_renderer_done(r) }
            if let l { ass_library_done(l) }
        }
    }

    /// Renders the picture for `ms` at `width`×`height` pixels.
    func render(ms: Int64, width: Int, height: Int, completion: @escaping @Sendable (Result) -> Void) {
        queue.async { [self] in
            guard let renderer, let track, width > 0, height > 0 else { return completion(.unchanged) }
            var forced = false
            if frame != (width, height) {
                frame = (width, height)
                ass_set_frame_size(renderer, Int32(width), Int32(height))
                ass_set_storage_size(renderer, Int32(width), Int32(height))
                forced = true
            }
            var changed: Int32 = 0
            let first = ass_render_frame(renderer, track, ms, &changed)
            guard changed != 0 || forced else { return completion(.unchanged) }
            completion(.image(Self.compose(first, width: width, height: height)))
        }
    }

    /// ASS_Image list (8-bit alpha masks with a color) → one premultiplied RGBA picture.
    private static func compose(_ first: UnsafeMutablePointer<ASS_Image>?, width: Int, height: Int) -> CGImage? {
        guard first != nil else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var node = first
        while let img = node?.pointee {
            let r = Int(img.color >> 24), g = Int((img.color >> 16) & 0xFF), b = Int((img.color >> 8) & 0xFF)
            let opacity = 255 - Int(img.color & 0xFF)
            if let bitmap = img.bitmap, opacity > 0 {
                for y in 0..<Int(img.h) {
                    let dy = Int(img.dst_y) + y
                    guard dy >= 0, dy < height else { continue }
                    for x in 0..<Int(img.w) {
                        let dx = Int(img.dst_x) + x
                        guard dx >= 0, dx < width else { continue }
                        let a = Int(bitmap[y * Int(img.stride) + x]) * opacity / 255
                        if a == 0 { continue }
                        let i = (dy * width + dx) * 4
                        let inv = 255 - a
                        pixels[i] = UInt8((r * a + Int(pixels[i]) * inv) / 255)
                        pixels[i + 1] = UInt8((g * a + Int(pixels[i + 1]) * inv) / 255)
                        pixels[i + 2] = UInt8((b * a + Int(pixels[i + 2]) * inv) / 255)
                        pixels[i + 3] = UInt8((255 * a + Int(pixels[i + 3]) * inv) / 255)
                    }
                }
            }
            node = img.next
        }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
