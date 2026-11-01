import AVFoundation
import Foundation
import Observation

/// One subtitle track of an episode, as listed by the server (or saved for offline use).
public struct SubtitleInfo: Codable, Hashable, Identifiable, Sendable {
    public let index: Int
    public let language: String?
    public let label: String
    public let isDefault: Bool
    public let isForced: Bool
    public let isSignsOnly: Bool
    public var url: URL
    public var id: Int { index }

    public init(index: Int, language: String?, label: String, isDefault: Bool, isForced: Bool, isSignsOnly: Bool, url: URL) {
        self.index = index; self.language = language; self.label = label
        self.isDefault = isDefault; self.isForced = isForced; self.isSignsOnly = isSignsOnly; self.url = url
    }
}

public struct SubtitleCue: Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let text: AttributedString
}

/// Minimal WebVTT reader: timings, multi-line text, overlapping cues, <i>/<b> styling.
public enum WebVTT {
    public static func parse(_ source: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        let blocks = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = time(parts[0]),
                  let end = time(parts[1].split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) ?? "")
            else { continue }
            let text = lines[(timingIndex + 1)...].joined(separator: "\n")
            guard !text.isEmpty, end > start else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: styled(text)))
        }
        return cues.sorted { $0.start < $1.start }
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

    /// <i>…</i> → italic, <b>…</b> → bold, any other tag removed, HTML entities decoded.
    static func styled(_ text: String) -> AttributedString {
        var result = AttributedString()
        var italic = false, bold = false
        var rest = Substring(text)
        while !rest.isEmpty {
            if rest.hasPrefix("<"), let close = rest.firstIndex(of: ">") {
                let tag = rest[rest.index(after: rest.startIndex)..<close].lowercased()
                switch tag {
                case "i": italic = true
                case "/i": italic = false
                case "b": bold = true
                case "/b": bold = false
                default: break
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
    /// Text to show now (overlapping cues joined, oldest first). nil = nothing on screen.
    public private(set) var text: AttributedString?
    /// Seconds added to every cue: positive = later. Remembered per series.
    public private(set) var offset: Double = 0
    public private(set) var isLoading = false

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
        text = nil
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

    /// Called by the player ~20 times a second with the playback time.
    public func update(time: Double) {
        guard selected != nil, !cues.isEmpty else { if text != nil { text = nil }; return }
        let t = time - offset
        // Last cue starting at or before t, then walk back while an earlier cue could still be on screen.
        var lo = 0, hi = cues.count
        while lo < hi { let mid = (lo + hi) / 2; if cues[mid].start <= t { lo = mid + 1 } else { hi = mid } }
        var active: [SubtitleCue] = []
        var i = lo - 1
        while i >= 0, cues[i].start >= t - longestCue {
            if cues[i].end > t { active.append(cues[i]) }
            i -= 1
        }
        let next: AttributedString? = active.isEmpty ? nil : active.reversed().dropFirst()
            .reduce(active.last!.text) { $0 + AttributedString("\n") + $1.text }
        if next != text { text = next }
    }

    // MARK: Private

    private func setOffset(_ value: Double) {
        offset = value
        if let seriesKey { UserDefaults.standard.set(value, forKey: seriesKey) }
    }

    private func apply(_ track: SubtitleInfo?) {
        loadTask?.cancel()
        selected = track
        cues = []; longestCue = 0; text = nil
        guard let track else { return }
        if let cached = cache[track.url] { setCues(cached); return }
        isLoading = true
        loadTask = Task { [weak self] in
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
