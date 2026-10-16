import os

/// Marks on the Instruments timeline.
///
/// A signpost is a named moment ("Thermal state") or interval ("Pieces",
/// from begin to end) that the app writes to the system log almost for free.
/// Instruments draws them above its own tracks, so a spike in CPU or a slow
/// frame lines up with what the app was doing at the time.
///
/// The category is `.pointsOfInterest`, which Time Profiler, Animation Hitches
/// and the other templates show by default. Elsewhere, add the
/// "os_signpost" instrument and filter by the subsystem `dev.chess.Chess`.
///
/// To record from the terminal (a Mac build; on an iPhone add `--device`):
///
///     xcrun xctrace record --template 'Time Profiler' --time-limit 30s \
///         --output chess.trace --launch -- path/to/Chess.app
///
/// Intervals the app marks:
/// - Launch, Bootstrap, Reconnect, Preload 3D: the splash screen, step by step;
/// - Pieces: the 3D board updating its pieces after a move ("moved 1,
///   removed 0, added 0"), or building all of them ("build all");
/// - Piece mesh, Wood texture: one-off work, cached afterwards;
/// - Move: from sending a move to the server's answer, the round trip a
///   player feels as lag.
/// Events: Thermal state, whenever it or Low Power Mode changes.
enum Signposts {
    nonisolated static let subsystem = "dev.chess.Chess"
    nonisolated static let poi = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)
    /// The same changes in words, for Console.app and `log stream`.
    nonisolated static let log = Logger(subsystem: subsystem, category: "performance")
}
