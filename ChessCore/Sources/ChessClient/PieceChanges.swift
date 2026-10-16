import ChessCore

/// What has to happen to the pieces on screen to turn one position into the
/// next: which pieces slide, which leave the board, which appear.
///
/// The 3D board used to throw every piece away and build 32 new ones after
/// each move, although a move touches two to four squares. Comparing the two
/// positions square by square (reconciliation, the same idea SwiftUI uses for
/// views) keeps everything that did not change:
///
/// | Move | moved | removed | added |
/// |---|---|---|---|
/// | e2e4 | e2→e4 | | |
/// | capture exd5 | e4→d5 | d5 (the black pawn) | |
/// | castling O-O | e1→g1, h1→f1 | | |
/// | en passant exd6 | e5→d6 | d5 | |
/// | promotion e7e8=Q | | e7 (the pawn) | e8 (the queen) |
///
/// Nothing here knows the rules: castling and en passant fall out of matching
/// vacated squares to filled ones by piece. So it also works for a position
/// that jumps several moves at once, such as a snapshot after a reconnect.
public struct PieceChanges: Equatable, Sendable {
    public var moved: [(from: Square, to: Square)] = []
    public var removed: [Square] = []
    public var added: [Square] = []

    public init(from old: Position, to new: Position, lastMove: Move? = nil) {
        // Squares whose piece left (or was replaced), and squares that need a
        // piece they do not have yet.
        var vacated = Square.all.filter { old[$0] != nil && old[$0] != new[$0] }
        var needed = Square.all.filter { new[$0] != nil && new[$0] != old[$0] }
        // The move's own destination first, so the piece that moved is the one
        // that slides there, not a twin of the same kind from elsewhere.
        if let to = lastMove?.to, let i = needed.firstIndex(of: to) {
            needed.insert(needed.remove(at: i), at: 0)
        }
        for target in needed {
            let candidates = vacated.filter { old[$0] == new[target] }
            let from =
                if let from = lastMove?.from, target == lastMove?.to, candidates.contains(from) {
                    from
                } else {
                    candidates.min { $0.distance(to: target) < $1.distance(to: target) }
                }
            if let from {
                moved.append((from, target))
                vacated.removeAll { $0 == from }
            } else {
                added.append(target)  // A promotion, or a piece we had no way to match.
            }
        }
        removed = vacated  // Captured, or turned into something else.
    }

    public var isEmpty: Bool { moved.isEmpty && removed.isEmpty && added.isEmpty }

    // Tuples are not Equatable on their own.
    public static func == (a: Self, b: Self) -> Bool {
        a.moved.elementsEqual(b.moved) { $0 == $1 } && a.removed == b.removed && a.added == b.added
    }
}

extension Square {
    /// How far apart two squares are, in king moves.
    fileprivate func distance(to other: Square) -> Int {
        max(abs(file - other.file), abs(rank - other.rank))
    }
}
