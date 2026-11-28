import Foundation
import Testing
@testable import ContainerKit

@Suite struct UpdatesTests {
    @Test(arguments: [
        ("1.8.0", "1.7.1", true), ("1.7.1", "1.7.1", false), ("1.7.10", "1.7.9", true),
        ("v1.6.1", "1.6.1-11-gb8439ea", false), ("1.7", "1.6.9", true), ("2.0", "10.0", false),
    ])
    func comparesVersions(candidate: String, installed: String, newer: Bool) {
        #expect(Updates.isNewer(candidate, than: installed) == newer)
    }

    @Test func unparsableVersionsAreUnknown() {
        #expect(Updates.isNewer("1.0", than: "dev") == nil)
    }

    @Test func parsesGitHubRelease() throws {
        let json = #"{"tag_name":"v1.6.1","html_url":"https://github.com/socktainer/socktainer/releases/tag/v1.6.1","published_at":"2026-11-09T22:48:05Z","draft":false}"#
        let release = try Updates.parseRelease(Data(json.utf8))
        #expect(release.version == "1.6.1")
        #expect(release.url.absoluteString.hasSuffix("/v1.6.1"))
        #expect(release.publishedAt != nil)
    }

    @Test func updateCommandStopsAndRestartsTheSystem() {
        let command = Updates.containerUpdateCommand(cli: URL(fileURLWithPath: "/usr/local/bin/container"),
                                                     script: URL(fileURLWithPath: "/usr/local/bin/update-container.sh"))
        #expect(command == "'/usr/local/bin/container' system stop && '/usr/local/bin/update-container.sh' && '/usr/local/bin/container' system start --enable-kernel-install")
    }
}

@Suite struct LogMatcherTests {
    @Test func plainTextIsCaseInsensitiveWithRanges() throws {
        let m = try #require(try LogMatcher.make("err", regex: false))
        #expect(m.matches("ERROR: Err again"))
        #expect(m.ranges(in: "ERROR: Err again") == [0..<3, 7..<10])
        #expect(try LogMatcher.make("", regex: true) == nil)
    }

    @Test func regexMatchesAlternativesAndCounts() throws {
        let m = try #require(try LogMatcher.make(#"timeout after \d+ms|refused"#, regex: true))
        #expect(m.matches("pg: Timeout after 250ms"))
        #expect(m.matches("connection REFUSED"))
        #expect(!m.matches("all good"))
        #expect(m.ranges(in: "é refused") == [2..<9]) // character offsets, not UTF-16
    }

    @Test func invalidRegexThrows() {
        #expect(throws: (any Error).self) { try LogMatcher.make("(unclosed", regex: true) }
    }
}
