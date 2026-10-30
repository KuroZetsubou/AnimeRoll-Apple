import Testing
import Foundation
@testable import AnimeRollKit

@Test func parsesDotNetDates() {
    #expect(APIClient.parseDate("2026-10-30T18:31:00.1234567Z") != nil)
    #expect(APIClient.parseDate("2026-10-30T18:31:00.1234567") != nil)
    #expect(APIClient.parseDate("2026-10-30T18:31:00Z") != nil)
}

@Test func base64URLRoundTrip() {
    let d = Data([0xfb, 0xff, 0x00, 0x10])
    #expect(Data(base64URL: d.base64URLEncoded) == d)
}
