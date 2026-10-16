import ChessClient
import SwiftUI

/// The game screen's layout: the board and the three rows around it,
/// stacked, side by side, or split by the fold of a half-open iPhone Duo
/// (`GameScreenGeometry` works out where everything goes; see there).
///
/// Why a `Layout` and not `if wide { HStack } else { VStack }`: the two
/// branches of an `if` are different views to SwiftUI. Crossing from one to
/// the other (rotating an iPad, unfolding or bending an iPhone Duo, resizing
/// a Mac window) throws the board away and makes a new one, and for the 3D
/// board that means building the RealityKit scene again. Here the children
/// are the same four views in the same order whatever the arrangement; only
/// where they are placed changes, so the board lives on, and the move
/// between arrangements animates.
///
/// Children, in this order: the top bar (opponent), the board, the player's
/// row, the details (status, moves, buttons, chat).
///
/// The arrangement, the board's shape and what the hardware takes of the
/// screen are given, not worked out here: the game screen decides once, so
/// the chat (a button, or inline in the column) follows the same decision as
/// the board, and the board here has the very shape it was decided with.
struct GameLayout: Layout {
    private typealias Geometry = GameScreenGeometry

    var arrangement: GameScreenGeometry.Arrangement
    /// The board's width over its height: square in 2D, a little wider than
    /// tall in 3D (`BoardScene.viewAspect`).
    var boardAspect: CGFloat
    /// Side by side and on a tabletop, the details take the whole free height
    /// (the chat is inline and scrolls) instead of sitting in its middle.
    var detailsFillColumn = false
    /// The fold, the hinge and the regions the camera and the Dynamic Island
    /// cover, in this layout's own coordinates (as its `GeometryProxy` gives
    /// them). See `GameScreenGeometry.plan`.
    var fold: CGRect? = nil
    var hinge = GameScreenGeometry.HingePose.none
    var occlusions: [CGRect] = []

    /// The rows' heights by width, so a row is never measured twice at the
    /// same width in a pass.
    ///
    /// Emptied at the start of every pass (`placeSubviews`): a row can grow
    /// from inside, with nothing here changing (the banner's countdown wraps
    /// onto a second line), and it is not certain SwiftUI calls `updateCache`
    /// for that. A height kept from an earlier pass could then be stale, and
    /// a stale height puts rows on top of each other; measuring three rows
    /// once more per pass costs little.
    /// `nonisolated`: `Layout`'s methods are not on the main actor, and the
    /// app's types are by default.
    nonisolated struct Cache {
        private nonisolated struct Key: Hashable {
            var row: Int
            var width: CGFloat
        }

        private var heights: [Key: CGFloat] = [:]

        mutating func height(of subviews: LayoutSubviews, _ row: Int, width: CGFloat) -> CGFloat {
            let key = Key(row: row, width: width)
            if let height = heights[key] {
                return height
            }
            let height = subviews[row].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            heights[key] = height
            return height
        }
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache()
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        guard subviews.count == 4 else { return }
        cache = Cache()
        // During a rotation this can run once with the new bounds and the
        // shape decided for the old ones (the game screen hears of the new
        // fold only after layout). The plan copes: a tabletop whose fold no
        // longer splits these bounds is laid out as a flat screen instead.
        let plan = Geometry.plan(
            in: bounds.size, boardAspect: boardAspect, arrangement: arrangement, fold: fold, hinge: hinge,
            occlusions: occlusions, detailsFillColumn: detailsFillColumn
        ) { width in
            Geometry.Chrome(
                topBar: cache.height(of: subviews, 0, width: width),
                playerRow: cache.height(of: subviews, 2, width: width),
                details: cache.height(of: subviews, 3, width: width))
        }

        // The plan's frames are in the screen's own coordinates, from (0, 0).
        func place(_ view: LayoutSubview, in frame: CGRect) {
            view.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                proposal: ProposedViewSize(frame.size))
        }
        place(subviews[0], in: plan.frames.topBar)
        place(subviews[1], in: plan.frames.board)
        place(subviews[2], in: plan.frames.playerRow)
        // Stacked and short of height, the details are offered less than
        // they would like and scroll (see `GameView.details`).
        place(subviews[3], in: plan.frames.details)
    }
}
