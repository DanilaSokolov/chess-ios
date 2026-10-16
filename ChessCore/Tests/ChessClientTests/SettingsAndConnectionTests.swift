import ChessCore
import ChessNet
import Foundation
import Testing

@testable import ChessClient

@MainActor
@Test func settingsSurviveARelaunch() throws {
    let suite = "chess-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let first = AppSettings(defaults: defaults)
    #expect(first.account == nil && first.serverURL == AppSettings.defaultServerURL && first.side == nil)
    first.account = .anonymous
    first.serverURL = "wss://chess.example/ws"
    first.side = .black
    first.resumeToken = "secret"
    first.prefersBoard3D = true

    let second = AppSettings(defaults: defaults)  // As if the app started again.
    #expect(second.account == .anonymous)
    #expect(second.serverURL == "wss://chess.example/ws")
    #expect(second.side == .black)
    #expect(second.resumeToken == "secret")
    #expect(second.prefersBoard3D && !second.prefersFacetedPieces)
}

@MainActor
@Test func onlyWebSocketAddressesAreAccepted() throws {
    let suite = "chess-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.serverURL = "http://localhost:8080/ws"
    #expect(settings.webSocketURL == nil)
    settings.serverURL = "ws://192.168.1.5:8080/ws"
    #expect(settings.webSocketURL?.host == "192.168.1.5")
}

@Test func reconnectPausesGrowThenLevelOff() {
    let pauses = (1...7).map { ConnectionManager.pause(afterAttempt: $0) }
    #expect(
        pauses == [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(5), .seconds(5), .seconds(5)])
    #expect(ConnectionManager.pause(afterAttempt: 1000) == .seconds(5), "no overflow on a long outage")
}

/// Property names may change; the stored keys must not, or an update would
/// silently reset everyone's settings.
@MainActor
@Test func settingsStoredBeforeTheRenameStillLoad() throws {
    let suite = "chess-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: "board3D")
    defaults.set(true, forKey: "facetedPieces")
    defaults.set("black", forKey: "side")

    let settings = AppSettings(defaults: defaults)
    #expect(settings.prefersBoard3D && settings.prefersFacetedPieces)
    #expect(settings.side == .black)
}

@Test func disconnectReasonsAreToldInWords() {
    #expect(
        DisconnectReason.network("The Internet connection appears to be offline.").text
            == "The Internet connection appears to be offline.")
    #expect(
        DisconnectReason.unreadableMessage.text
            == "the server sent a message this version of the app cannot read")
}
