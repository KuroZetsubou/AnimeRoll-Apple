import Foundation
import Testing
@testable import AnimeRollKit

/// Offline downloads store their metadata with `APIClient.encoder` and read it with `APIClient.decoder`.
@Suite struct OfflineMetadataTests {
    let seriesJSON = #"{"id":1,"title":"T","episodeCount":1,"updatedAt":"2026-10-30T23:00:00.1234567Z"}"#

    @Test func roundTripsThroughEncoderAndDecoder() throws {
        let series = try APIClient.decoder.decode(SeriesDTO.self, from: Data(seriesJSON.utf8))
        let again = try APIClient.decoder.decode(SeriesDTO.self, from: APIClient.encoder.encode(series))
        #expect(abs(again.updatedAt.timeIntervalSince(series.updatedAt)) < 0.001)
    }

    @Test func readsMetadataSavedByOlderBuilds() throws {
        let legacy = #"{"id":1,"title":"T","episodeCount":1,"updatedAt":815094000.123}"#
        let series = try APIClient.decoder.decode(SeriesDTO.self, from: Data(legacy.utf8))
        #expect(series.updatedAt == Date(timeIntervalSinceReferenceDate: 815094000.123))
    }
}
