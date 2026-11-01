import Foundation
import Testing
@testable import AnimeRollKit

private let sample = """
WEBVTT

00:01.000 --> 00:05.000
CARTELLO: Villaggio

00:02.000 --> 00:03.000 align:middle
<i>Riga A</i> &amp; basta

00:01:00.000 --> 00:01:02.500
Riga D
seconda linea
"""

private func plain(_ s: AttributedString?) -> String? { s.map { String($0.characters) } }

@Test func parsesTimingsTextAndTags() {
    let cues = WebVTT.parse(sample)
    #expect(cues.count == 3)
    #expect(cues[0].start == 1 && cues[0].end == 5)
    #expect(plain(cues[1].text) == "Riga A & basta")
    #expect(cues[1].text.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
    #expect(cues[2].start == 60 && cues[2].end == 62.5)
    #expect(plain(cues[2].text) == "Riga D\nseconda linea")
}

@MainActor
private func controller(series: Int) async throws -> SubtitleController {
    let file = FileManager.default.temporaryDirectory.appending(path: "test-\(UUID()).vtt")
    try sample.write(to: file, atomically: true, encoding: .utf8)
    UserDefaults.standard.set("auto", forKey: "subtitles.language")
    UserDefaults.standard.set(0.0, forKey: "subtitles.offset.\(series)")
    let c = SubtitleController()
    c.setTracks([SubtitleInfo(index: 2, language: "ita", label: "Italiano", isDefault: false, isForced: false, isSignsOnly: false, url: file)],
                seriesId: series)
    for _ in 0..<50 where c.isLoading { try await Task.sleep(for: .milliseconds(20)) }
    return c
}

@Test @MainActor func showsOverlappingCuesTogether() async throws {
    let c = try await controller(series: 998)
    c.update(time: 0.5); #expect(c.text == nil)
    c.update(time: 1.5); #expect(plain(c.text) == "CARTELLO: Villaggio")
    c.update(time: 2.5); #expect(plain(c.text) == "CARTELLO: Villaggio\nRiga A & basta")   // sign stays on screen
    c.update(time: 4.0); #expect(plain(c.text) == "CARTELLO: Villaggio")
    c.update(time: 61); #expect(plain(c.text) == "Riga D\nseconda linea")
    c.update(time: 63); #expect(c.text == nil)
}

@Test @MainActor func offsetShiftsAndIsRemembered() async throws {
    let c = try await controller(series: 999)
    c.nudge(by: 0.5)                      // subtitles 0.5 s later
    c.update(time: 1.2); #expect(c.text == nil)
    c.update(time: 1.6); #expect(plain(c.text) == "CARTELLO: Villaggio")
    #expect(UserDefaults.standard.double(forKey: "subtitles.offset.999") == 0.5)
    c.resetOffset()
}

@Test func picksFullTrackInPreferredLanguage() {
    let u = URL(string: "https://x/s.vtt")!
    let signs = SubtitleInfo(index: 3, language: "ita", label: "Italiano – Cartelli", isDefault: true, isForced: true, isSignsOnly: true, url: u)
    let eng = SubtitleInfo(index: 4, language: "eng", label: "English", isDefault: false, isForced: false, isSignsOnly: false, url: u)
    let ita = SubtitleInfo(index: 5, language: "ita", label: "Italiano", isDefault: false, isForced: false, isSignsOnly: false, url: u)
    #expect(SubtitleController.pick(from: [signs, eng, ita], preference: "it")?.index == 5)
    #expect(SubtitleController.pick(from: [signs, eng, ita], preference: "eng")?.index == 4)
    #expect(SubtitleController.pick(from: [signs, eng], preference: "ita")?.index == 4)   // never signs-only when a full track exists
    #expect(SubtitleController.pick(from: [signs], preference: "auto")?.index == 3)
    #expect(SubtitleController.pick(from: [eng, ita], preference: "off") == nil)
    #expect(SubtitleController.matches("ita", "it") && SubtitleController.matches("eng", "en") && !SubtitleController.matches("eng", "it"))
}
