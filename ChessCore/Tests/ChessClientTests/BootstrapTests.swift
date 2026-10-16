import ChessNet
import Foundation
import Testing

@testable import ChessClient

let serverJSON = Data(
    """
    {"client":{"status":"outdated","minVersion":"0.1.0","latestVersion":"0.2.0","updateURL":"https://apps.apple.com/app/id0"},
     "timeControls":[{"initialSeconds":60,"incrementSeconds":0},{"initialSeconds":180,"incrementSeconds":2}]}
    """.utf8)

@Test func decodesTheServersAnswer() throws {
    let b = try JSONDecoder().decode(Bootstrap.self, from: serverJSON)
    #expect(b.client.status == .outdated)
    #expect(b.client.updateURL?.host == "apps.apple.com")
    #expect(b.lobbyTimeControls == [TimeControl(minutes: 1, increment: 0), TimeControl(minutes: 3, increment: 2)])
}

@Test func unknownStatusStillLetsPeoplePlay() throws {
    let json = Data(#"{"client":{"status":"deprecated","minVersion":"1","latestVersion":"2"},"timeControls":[]}"#.utf8)
    let b = try JSONDecoder().decode(Bootstrap.self, from: json)
    #expect(b.client.status == .outdated)
    #expect(b.lobbyTimeControls == TimeControl.presets, "no list from the server: the built-in presets")
}

@Test func cacheIsOnlyTrustedForTheSameAppVersion() throws {
    let b = try JSONDecoder().decode(Bootstrap.self, from: serverJSON)
    let old = BootstrapLoader(appVersion: "0.1", language: nil)
    let stored = old.cache(b)
    #expect(old.cached(in: stored) == b)
    #expect(
        BootstrapLoader(appVersion: "0.2", language: nil).cached(in: stored) == nil, "an update voids the old verdict")
    #expect(old.cached(in: nil) == nil)
    #expect(old.cached(in: Data("garbage".utf8)) == nil)
}

@Test func unreachableServerGivesNil() async {
    // Nothing listens on port 9 (discard) locally; fetch must fail, not hang or crash.
    let loader = BootstrapLoader(appVersion: "0.1", language: nil)
    #expect(await loader.fetch(from: URL(string: "ws://127.0.0.1:9/ws")!) == nil)
}
