import AVFoundation
import Foundation
import Observation
import SwiftUI

/// One subtitle track of an episode, as listed by the server (or saved for offline use).
public struct SubtitleInfo: Codable, Hashable, Identifiable, Sendable {
    public let index: Int
    public let language: String?
    public let label: String
    public let isDefault: Bool
    public let isForced: Bool
    public let isSignsOnly: Bool
    public var url: URL
    /// The original ASS, when the source had one: drawn by libass for the full look. nil = WebVTT only.
    public var assUrl: URL?
    public var id: Int { index }

    public init(index: Int, language: String?, label: String, isDefault: Bool, isForced: Bool, isSignsOnly: Bool, url: URL, assUrl: URL? = nil) {
        self.index = index; self.language = language; self.label = label
        self.isDefault = isDefault; self.isForced = isForced; self.isSignsOnly = isSignsOnly; self.url = url; self.assUrl = assUrl
    }
}

/// Where a cue sits when it is not the plain bottom-centered line (WebVTT cue settings), all as 0...1 of the picture.
public struct CueLayout: Equatable, Sendable {
    public enum Align: Sendable { case left, center, right }
    public enum Anchor: Sendable { case start, center, end }
    /// Vertical position of the text box, and which edge of it that position refers to.
    public var line: Double?
    public var lineAnchor: Anchor = .start
    /// Horizontal position of the text box, and which edge of it that position refers to (the alignment).
    public var position: Double?
    public var align: Align = .center
    /// Width of the text box as a fraction of the picture.
    public var size: Double?
}

public struct SubtitleCue: Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let text: AttributedString
    /// nil = plain cue, drawn with the others at the bottom.
    public var layout: CueLayout? = nil
}

/// WebVTT reader: timings, multi-line text, overlapping cues, cue settings (line, position, align, size)
/// and <i> <b> <u> / <c.c_rrggbb> styling.
public enum WebVTT {
    public static func parse(_ source: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        let blocks = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            let tokens = parts.count == 2 ? parts[1].split(separator: " ", omittingEmptySubsequences: true).map(String.init) : []
            guard parts.count == 2,
                  let start = time(parts[0]),
                  let end = time(tokens.first ?? "")
            else { continue }
            let text = lines[(timingIndex + 1)...].joined(separator: "\n")
            guard !text.isEmpty, end > start else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: styled(text), layout: layout(Array(tokens.dropFirst()))))
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// "line:10%,end position:93% align:right size:40%" → layout. Line numbers (not percentages) are ignored.
    static func layout(_ settings: [String]) -> CueLayout? {
        var l = CueLayout()
        var any = false
        func pct(_ v: Substring) -> Double? { v.hasSuffix("%") ? Double(v.dropLast()).map { $0 / 100 } : nil }
        for token in settings {
            let kv = token.split(separator: ":", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let parts = kv[1].split(separator: ",")
            guard let first = parts.first else { continue }
            switch kv[0] {
            case "line":
                if let v = pct(first) {
                    l.line = v; any = true
                    switch parts.dropFirst().first {
                    case "end": l.lineAnchor = .end
                    case "center": l.lineAnchor = .center
                    default: l.lineAnchor = .start
                    }
                }
            case "position": if let v = pct(first) { l.position = v; any = true }
            case "size": if let v = pct(first) { l.size = v; any = true }
            case "align":
                switch first {
                case "left", "start": l.align = .left; any = true
                case "right", "end": l.align = .right; any = true
                default: break
                }
            default: break
            }
        }
        return any ? l : nil
    }

    /// "01:02:03.456" or "02:03.456" → seconds.
    static func time(_ raw: String) -> Double? {
        let parts = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var seconds = 0.0
        for p in parts {
            guard let v = Double(p) else { return nil }
            seconds = seconds * 60 + v
        }
        return seconds
    }

    /// <i> <b> <u> and <c.c_rrggbb> are drawn, any other tag is removed, HTML entities are decoded.
    static func styled(_ text: String) -> AttributedString {
        var result = AttributedString()
        var italic = false, bold = false, underline = false
        var colors: [Color] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            if rest.hasPrefix("<"), let close = rest.firstIndex(of: ">") {
                let tag = rest[rest.index(after: rest.startIndex)..<close].lowercased()
                switch tag {
                case "i": italic = true
                case "/i": italic = false
                case "b": bold = true
                case "/b": bold = false
                case "u": underline = true
                case "/u": underline = false
                case "/c": if !colors.isEmpty { colors.removeLast() }
                default:
                    if tag.hasPrefix("c") {
                        // <c.c_ff8800.other> → the first class that looks like c_rrggbb; otherwise it just closes with </c>.
                        let hex = tag.split(separator: ".").first { $0.hasPrefix("c_") && $0.count == 8 }.map { String($0.dropFirst(2)) }
                        colors.append(hex.flatMap(Color.init(hex:)) ?? colors.last ?? .white)
                    }
                }
                rest = rest[rest.index(after: close)...]
                continue
            }
            let next = rest.firstIndex(of: "<") ?? rest.endIndex
            var run = AttributedString(decode(String(rest[..<next])))
            var intent: InlinePresentationIntent = []
            if italic { intent.insert(.emphasized) }
            if bold { intent.insert(.stronglyEmphasized) }
            if !intent.isEmpty { run.inlinePresentationIntent = intent }
            if underline { run.underlineStyle = .single }
            if let color = colors.last, color != .white { run.foregroundColor = color }
            result += run
            rest = rest[next...]
        }
        return result
    }

    private static func decode(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: "\u{00A0}").replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// Picks, loads and times the subtitles of the playing episode.
/// Rendered by the apps as an overlay: unlike subtitles inside the MP4 they handle overlapping
/// lines, turn on automatically and can be nudged when a release is out of sync.
@MainActor
@Observable
public final class SubtitleController {
    public private(set) var tracks: [SubtitleInfo] = []
    public private(set) var selected: SubtitleInfo?
    /// Cues on screen now, oldest first. Empty = nothing on screen.
    public private(set) var active: [SubtitleCue] = []
    /// Seconds added to every cue: positive = later. Remembered per series.
    public private(set) var offset: Double = 0
    public private(set) var isLoading = false
    /// Picture from libass for the current time (ASS tracks); nil = nothing on screen. `usesAss` tells the overlay which path is active.
    public private(set) var assImage: CGImage?
    public private(set) var usesAss = false

    @ObservationIgnored private var ass: AssRenderer?
    @ObservationIgnored private var assBusy = false
    @ObservationIgnored private var renderPixels = CGSize.zero

    @ObservationIgnored private var cues: [SubtitleCue] = []
    @ObservationIgnored private var longestCue = 0.0
    @ObservationIgnored private var seriesKey: String?
    @ObservationIgnored private var cache: [URL: [SubtitleCue]] = [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    private static let preferenceKey = "subtitles.language"   // "off", "auto" or a language code
    public static let offsetStep = 0.25

    public init() {}

    /// New episode: keep the user's language choice, pick the best track, load it.
    public func setTracks(_ tracks: [SubtitleInfo], seriesId: Int?) {
        self.tracks = tracks
        seriesKey = seriesId.map { "subtitles.offset.\($0)" }
        offset = seriesKey.map { UserDefaults.standard.double(forKey: $0) } ?? 0
        active = []
        apply(Self.pick(from: tracks, preference: UserDefaults.standard.string(forKey: Self.preferenceKey) ?? "auto"))
    }

    /// Choice made by the user: becomes the default for the next episodes.
    public func select(_ track: SubtitleInfo?) {
        UserDefaults.standard.set(track.map { $0.language ?? "auto" } ?? "off", forKey: Self.preferenceKey)
        apply(track)
    }

    public func nudge(by delta: Double) {
        setOffset(((offset + delta) * 100).rounded() / 100)
    }

    public func resetOffset() { setOffset(0) }

    /// Size in pixels of the area libass draws into (the picture), reported by the overlay.
    public func setRenderSize(_ size: CGSize) { renderPixels = size }

    /// Called by the player ~20 times a second with the playback time.
    public func update(time: Double) {
        if let ass {
            guard !assBusy, renderPixels.width > 0 else { return }
            assBusy = true
            let ms = Int64(((time - offset) * 1000).rounded())
            ass.render(ms: ms, width: Int(renderPixels.width), height: Int(renderPixels.height)) { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    self.assBusy = false
                    if case .image(let image) = result, self.ass != nil { self.assImage = image }
                }
            }
            return
        }
        guard selected != nil, !cues.isEmpty else { if !active.isEmpty { active = [] }; return }
        let t = time - offset
        // Last cue starting at or before t, then walk back while an earlier cue could still be on screen.
        var lo = 0, hi = cues.count
        while lo < hi { let mid = (lo + hi) / 2; if cues[mid].start <= t { lo = mid + 1 } else { hi = mid } }
        var now: [SubtitleCue] = []
        var i = lo - 1
        while i >= 0, cues[i].start >= t - longestCue {
            if cues[i].end > t { now.append(cues[i]) }
            i -= 1
        }
        now.reverse()
        if now != active { active = now }
    }

    // MARK: Private

    private func setOffset(_ value: Double) {
        offset = value
        if let seriesKey { UserDefaults.standard.set(value, forKey: seriesKey) }
    }

    private func apply(_ track: SubtitleInfo?) {
        loadTask?.cancel()
        selected = track
        cues = []; longestCue = 0; active = []
        ass = nil; assImage = nil; usesAss = false; assBusy = false
        guard let track else { return }
        if let cached = cache[track.url] { setCues(cached); return }
        isLoading = true
        loadTask = Task { [weak self] in
            // ASS first (fonts embedded by the server); WebVTT when there is no ASS or libass can't read it.
            if let assUrl = track.assUrl, let renderer = await Self.loadAss(assUrl) {
                guard let self, !Task.isCancelled, self.selected == track else { return }
                self.ass = renderer; self.usesAss = true; self.isLoading = false
                return
            }
            let parsed = await Self.download(track.url)
            guard let self, !Task.isCancelled, self.selected == track else { return }
            self.cache[track.url] = parsed
            self.setCues(parsed)
            self.isLoading = false
        }
    }

    private func setCues(_ list: [SubtitleCue]) {
        cues = list
        longestCue = list.map { $0.end - $0.start }.max() ?? 0
    }

    private nonisolated static func loadAss(_ url: URL) async -> AssRenderer? {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if !url.isFileURL {
            let items = comps?.queryItems ?? []
            comps?.queryItems = items + [URLQueryItem(name: "embed", value: "1")]
        }
        guard let target = comps?.url,
              let data = target.isFileURL ? try? Data(contentsOf: target) : try? await URLSession.shared.data(from: target).0 else { return nil }
        return AssRenderer(data: data)
    }

    private nonisolated static func download(_ url: URL) async -> [SubtitleCue] {
        guard let data = url.isFileURL ? try? Data(contentsOf: url) : try? await URLSession.shared.data(from: url).0,
              let source = String(data: data, encoding: .utf8) else { return [] }
        return WebVTT.parse(source)
    }

    /// "off" → none. A language code → that language. "auto" → the device languages in order.
    /// Full tracks always beat "signs & songs" tracks; a signs-only track is used only when nothing else exists.
    nonisolated static func pick(from tracks: [SubtitleInfo], preference: String) -> SubtitleInfo? {
        if preference == "off" || tracks.isEmpty { return nil }
        let full = tracks.filter { !$0.isSignsOnly }
        let wanted = preference == "auto"
            ? Locale.preferredLanguages.compactMap { Locale(identifier: $0).language.languageCode?.identifier } + ["en"]
            : [preference]
        for code in wanted {
            if let match = full.first(where: { matches($0.language, code) }) { return match }
        }
        return full.first(where: \.isDefault) ?? full.first ?? tracks.first
    }

    /// "ita" (ISO 639-2) matches "it" (ISO 639-1) and vice versa.
    nonisolated static func matches(_ trackLanguage: String?, _ code: String) -> Bool {
        guard let lang = trackLanguage?.lowercased() else { return false }
        let a = Locale.LanguageCode(lang), b = Locale.LanguageCode(code.lowercased())
        return lang == code.lowercased()
            || a.identifier(.alpha2) == b.identifier(.alpha2) && a.identifier(.alpha2) != nil
    }
}

extension Color {
    /// "rrggbb"
    init?(hex: String) {
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        self.init(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
