import CoreGraphics

/// Where things go on the game screen: the arithmetic behind the app's
/// `GameLayout`, kept apart from SwiftUI so tests can check it.
///
/// The screen has three arrangements:
/// - **stacked**: the opponent's row, the board, the player's row, then the
///   rest (status, moves, buttons) at the bottom. A phone held upright.
/// - **side by side**: the board on one side, everything else in a column
///   on the other. An iPad on its side, a Mac window, an iPhone Duo held
///   half open like a book (then the fold is the boundary between the two).
/// - **tabletop**: an iPhone Duo half open with the fold across the screen,
///   standing on a table like a small laptop: the board and the player's row
///   on the lower half, which lies on the table, and the opponent, the
///   status, the moves and the chat on the upper half, which faces the player.
///
/// Flat, stacked or side by side is not decided by the device or by "is it
/// landscape": it is whichever gives the board more room. That rule needs no
/// special case for an unfolded iPhone Duo (nearly square) or an iPad in
/// Split View: it works out the board size both ways and takes the bigger
/// one. Only a half-open hinge decides by itself (tabletop or book), because
/// then the fold splits the screen into two halves whatever their sizes, and
/// nothing may sit in the fold.
///
/// All frames are in the screen's own coordinates: (0, 0) is its top left
/// corner, as in a SwiftUI `GeometryProxy`'s local space.
public struct GameScreenGeometry: Equatable, Sendable {
    public enum Arrangement: Equatable, Sendable {
        case stacked
        case sideBySide
        /// Half open with the fold across: the board below the fold, the rest above.
        case tabletop
    }

    /// The hinge of a foldable, as the system reports it. A plain value of
    /// our own so that this module needs no SwiftUI: the app turns SwiftUI's
    /// `DeviceHinge` into it.
    public enum HingePose: Equatable, Sendable {
        /// No hinge reported: a device that does not fold, or one that has
        /// not said anything yet.
        case none
        case closed
        case partiallyOpen
        case fullyOpen
    }

    /// The heights the board has to share the screen with, at a given width.
    public struct Chrome: Equatable, Sendable {
        public var topBar: CGFloat
        public var playerRow: CGFloat
        /// Status, notices, moves and buttons, and whatever chat `chatButton`
        /// leaves out.
        public var details: CGFloat
        /// The chat as a button under the details, with the space above it,
        /// when `details` does not already include it. Stacked, it is always
        /// there; side by side and on a tabletop it may give way to the chat
        /// itself, so the room for that is worked out without it.
        public var chatButton: CGFloat

        public init(topBar: CGFloat, playerRow: CGFloat, details: CGFloat, chatButton: CGFloat = 0) {
            self.topBar = topBar
            self.playerRow = playerRow
            self.details = details
            self.chatButton = chatButton
        }

        /// About what the rows take: enough to choose the arrangement before
        /// anything is measured. The game screen replaces it with the heights
        /// it measures as soon as the rows are on screen.
        public static let estimate = Chrome(topBar: 36, playerRow: 36, details: 110, chatButton: 50)
    }

    /// Where each of the four views goes, in the screen's coordinates.
    public struct Frames: Equatable, Sendable {
        public var topBar: CGRect
        public var board: CGRect
        public var playerRow: CGRect
        public var details: CGRect

        public init(topBar: CGRect, board: CGRect, playerRow: CGRect, details: CGRect) {
            self.topBar = topBar
            self.board = board
            self.playerRow = playerRow
            self.details = details
        }
    }

    public static let margin: CGFloat = 16
    /// Between the rows and the board.
    public static let spacing: CGFloat = 10
    /// The least space between the player's row and the details when stacked.
    public static let minGap: CGFloat = 8
    /// Between the board and the column when side by side.
    public static let columnGap: CGFloat = 24
    /// Hysteresis between stacked and side by side. Side by side has to win
    /// by this much to replace stacked, and stacked by as much to replace
    /// side by side; when both give about the same board, the screen stays
    /// as it is. So a window resized back and forth across the point where
    /// both are equal does not flip on every point; it still switches, once,
    /// when it leaves that ±5% band.
    public static let switchMargin: CGFloat = 1.05
    /// The least board stacked, when the rows take nearly all the height (a
    /// small window, Split View, the largest Dynamic Type): a board too small
    /// to play on helps no one, so the details give up height instead and
    /// scroll. Never wider than the screen.
    public static let minBoard: CGFloat = 200

    public var arrangement: Arrangement
    /// The board's size. Not always square: the 3D board is a little wider
    /// than tall (the camera looks at it at an angle).
    public var boardSize: CGSize
    /// The column's width side by side; the full width less margins, stacked
    /// and on a tabletop.
    public var panelWidth: CGFloat
    public var frames: Frames
    /// Side by side and on a tabletop: the height left for the chat under
    /// the details, when `Chrome.details` was given without the chat. Zero
    /// stacked, where the chat is always a button.
    public var chatRoom: CGFloat

    /// The least room the chat needs to sit in the column, side by side,
    /// under the opponent's row, the status, moves and buttons: a few
    /// messages and the field to type in. With less (a phone on its side)
    /// it stays a button that opens a sheet.
    public static let minInlineChat: CGFloat = 200

    /// Whether the chat fits beside (or above) the board instead of in a sheet.
    public var hasRoomForInlineChat: Bool {
        arrangement != .stacked && chatRoom >= Self.minInlineChat
    }

    /// Whether the chat fits in the column of a flat side-by-side screen of `size`.
    public static func fitsInlineChat(in size: CGSize, chrome: Chrome = .estimate) -> Bool {
        plan(in: size, arrangement: .sideBySide) { _ in chrome }.hasRoomForInlineChat
    }

    /// The column's width side by side: wide enough for the clock and the
    /// buttons, never more than 380 points.
    public static func columnWidth(for width: CGFloat) -> CGFloat {
        max(0, min(380, width * 0.38))
    }

    /// The biggest board of `aspect` (width / height) that fits `width` × `height`.
    static func fit(aspect: CGFloat, width: CGFloat, height: CGFloat) -> CGSize {
        let w = max(0, min(width, height * aspect))
        return CGSize(width: w, height: w / aspect)
    }

    /// `bounds` less what the hardware covers: the camera, the Dynamic Island,
    /// a window's controls (SwiftUI's active `.occlusion` regions, in the same
    /// coordinates). Each one pushes in only the edge it is cheapest to clear
    /// it from (normally the edge it sits on), so a camera on the left of a
    /// phone on its side insets the left and nothing else: the insets are
    /// as uneven as the hardware. Regions outside `bounds` change nothing.
    public static func safeArea(of bounds: CGRect, avoiding occlusions: [CGRect]) -> CGRect {
        var top: CGFloat = 0
        var left: CGFloat = 0
        var bottom: CGFloat = 0
        var right: CGFloat = 0
        for region in occlusions where overlaps(region, bounds) {
            // How far each edge would have to move in to clear the region.
            let fromTop = region.maxY - bounds.minY
            let fromBottom = bounds.maxY - region.minY
            let fromLeft = region.maxX - bounds.minX
            let fromRight = bounds.maxX - region.minX
            let least = min(fromTop, fromBottom, fromLeft, fromRight)
            if least == fromTop {
                top = max(top, fromTop)
            } else if least == fromBottom {
                bottom = max(bottom, fromBottom)
            } else if least == fromLeft {
                left = max(left, fromLeft)
            } else {
                right = max(right, fromRight)
            }
        }
        return CGRect(
            x: min(bounds.minX + left, bounds.maxX), y: min(bounds.minY + top, bounds.maxY),
            width: max(0, bounds.width - left - right), height: max(0, bounds.height - top - bottom))
    }

    /// Picks the arrangement for a screen of `size` and works out where
    /// everything goes.
    ///
    /// - `boardAspect`: the board's width over its height.
    /// - `arrangement`: if given, used as is (decided elsewhere, so that
    ///   everyone uses the same one); otherwise chosen here. The exception
    ///   is a tabletop with no fold across these bounds: that one is laid
    ///   out as a flat screen, stacked or side by side, whichever is better.
    /// - `current`: the arrangement on screen now, for the hysteresis (see
    ///   `switchMargin`). Ignored when `arrangement` is given.
    /// - `fold`, `hinge`: the fold of a foldable (SwiftUI's active `.division`
    ///   region) and its hinge. The fold shapes the screen only while the
    ///   hinge is partially open (or not yet reported, see `Posture`):
    ///   across, the screen is a tabletop; down, a book, side by side with
    ///   the fold as the boundary. Flat or closed it is ignored, and the
    ///   board may run across it.
    /// - `occlusions`: active `.occlusion` regions; nothing goes under them.
    /// - `detailsFillColumn`: side by side and on a tabletop, the details take
    ///   all the free height (the chat is inline and scrolls) instead of
    ///   sitting in its middle.
    /// - `chrome`: the heights of the other rows at a width (they wrap, so it
    ///   matters).
    public static func plan(
        in size: CGSize, boardAspect: CGFloat = 1, arrangement: Arrangement? = nil, current: Arrangement? = nil,
        fold: CGRect? = nil, hinge: HingePose = .none, occlusions: [CGRect] = [], detailsFillColumn: Bool = false,
        chrome: (CGFloat) -> Chrome
    ) -> GameScreenGeometry {
        let aspect = boardAspect > 0 ? boardAspect : 1
        let bounds = CGRect(x: 0, y: 0, width: max(0, size.width), height: max(0, size.height))
        let safe = safeArea(of: bounds, avoiding: occlusions)
        let posture = Posture(fold: fold, hinge: hinge, in: safe)

        let chosen: Arrangement
        if let arrangement {
            chosen = arrangement
        } else {
            switch posture {
            case .tabletop: chosen = .tabletop
            case .book: chosen = .sideBySide
            case .flat: chosen = compare(in: safe, aspect: aspect, current: current, chrome: chrome)
            }
        }

        switch (chosen, posture) {
        case (.tabletop, .tabletop(let fold)):
            return tabletop(in: safe, fold: fold, aspect: aspect, fill: detailsFillColumn, chrome: chrome)
        case (.tabletop, _):
            // A tabletop asked for with no fold across the screen to split
            // it by. It happens for one layout pass during a rotation: the
            // game screen learns the new fold only after layout (in
            // `onGeometryChange`), so the layout can get the new size with
            // the old fold, which then lies off the screen or runs down it.
            // That fold is not to be trusted, so it is ignored, and the flat
            // screen gets the better of stacked and side by side, as it
            // would with no fold: a phone layout on a wide screen would make
            // the board jump down and back up for that one frame.
            switch compare(in: safe, aspect: aspect, current: nil, chrome: chrome) {
            case .sideBySide:
                return sideBySide(in: safe, aspect: aspect, fill: detailsFillColumn, chrome: chrome)
            case .stacked, .tabletop:
                return stacked(in: safe, aspect: aspect, chrome: chrome)
            }
        case (.sideBySide, .book(let fold)):
            return book(in: safe, fold: fold, aspect: aspect, fill: detailsFillColumn, chrome: chrome)
        case (.sideBySide, _):
            return sideBySide(in: safe, aspect: aspect, fill: detailsFillColumn, chrome: chrome)
        case (.stacked, _):
            return stacked(in: safe, aspect: aspect, chrome: chrome)
        }
    }

    /// How the fold divides the screen, if it does.
    private enum Posture {
        case flat
        /// The fold runs across the screen (wider than tall).
        case tabletop(CGRect)
        /// The fold runs down the screen.
        case book(CGRect)

        /// The hinge decides when it has spoken. Before it has (`.none`:
        /// `onHingeChange` reports only changes, so a game opened on a
        /// device already half open has heard nothing yet), an active fold
        /// is enough: the system makes the fold active only while the device
        /// is partially open.
        init(fold: CGRect?, hinge: HingePose, in bounds: CGRect) {
            let halfOpen = hinge == .partiallyOpen || (hinge == .none && fold != nil)
            guard halfOpen, let fold, let clipped = GameScreenGeometry.clip(fold, to: bounds) else {
                self = .flat
                return
            }
            self = clipped.width > clipped.height ? .tabletop(clipped) : .book(clipped)
        }
    }

    /// Stacked or side by side on a flat screen: whichever gives the bigger
    /// board, with the hysteresis of `switchMargin` in favour of `current`.
    private static func compare(
        in safe: CGRect, aspect: CGFloat, current: Arrangement?, chrome: (CGFloat) -> Chrome
    ) -> Arrangement {
        // Stacked: the board runs edge to edge, so the width limits it on a
        // phone; the height has to fit the rows too. (Without `minBoard`:
        // this is about which arrangement has more room.)
        let rows = chrome(max(0, safe.width - 2 * margin))
        let stacked = fit(aspect: aspect, width: safe.width, height: stackedRoom(in: safe, rows: rows))
        // Side by side: the board gets what the column leaves.
        let side = fit(
            aspect: aspect, width: safe.width - 2 * margin - columnGap - columnWidth(for: safe.width),
            height: safe.height - 2 * margin)
        // The same aspect both ways, so comparing widths compares the boards.
        if current == .sideBySide {
            return side.width < stacked.width / switchMargin ? .stacked : .sideBySide
        }
        return side.width > stacked.width * switchMargin ? .sideBySide : .stacked
    }

    /// The height left for the board stacked, once the rows have theirs.
    private static func stackedRoom(in safe: CGRect, rows: Chrome) -> CGFloat {
        let rowsHeight = rows.topBar + rows.playerRow + rows.details + rows.chatButton
        return safe.height - 2 * margin - rowsHeight - 3 * spacing - minGap
    }

    private static func stacked(in safe: CGRect, aspect: CGFloat, chrome: (CGFloat) -> Chrome) -> GameScreenGeometry {
        let width = max(0, safe.width - 2 * margin)
        let rows = chrome(width)
        var board = fit(aspect: aspect, width: safe.width, height: stackedRoom(in: safe, rows: rows))
        let least = fit(aspect: aspect, width: safe.width, height: min(minBoard, max(0, safe.height - 2 * margin)))
        if board.width < least.width {
            board = least
        }

        // The rows hug the board, as on a real table; spare height goes
        // between the player's row and the details, which sit at the bottom.
        // Short of height, the details get what is left below the player's
        // row and no more: they never slide up over it.
        let x = safe.minX + margin
        let topBar = CGRect(x: x, y: safe.minY + margin, width: width, height: rows.topBar)
        let boardFrame = CGRect(
            x: safe.midX - board.width / 2, y: topBar.maxY + spacing, width: board.width, height: board.height)
        let playerRow = CGRect(x: x, y: boardFrame.maxY + spacing, width: width, height: rows.playerRow)
        let detailsTop = playerRow.maxY + spacing + minGap
        let bottom = safe.maxY - margin
        let detailsHeight = min(rows.details + rows.chatButton, max(0, bottom - detailsTop))
        let details = CGRect(x: x, y: max(detailsTop, bottom - detailsHeight), width: width, height: detailsHeight)
        return GameScreenGeometry(
            arrangement: .stacked, boardSize: board, panelWidth: width,
            frames: Frames(topBar: topBar, board: boardFrame, playerRow: playerRow, details: details),
            chatRoom: 0)
    }

    private static func sideBySide(
        in safe: CGRect, aspect: CGFloat, fill: Bool, chrome: (CGFloat) -> Chrome
    ) -> GameScreenGeometry {
        // The column on the right, the board in the space it leaves, centred.
        let content = shrink(safe, by: margin)
        let panel = min(columnWidth(for: safe.width), content.width)
        let column = CGRect(x: content.maxX - panel, y: content.minY, width: panel, height: content.height)
        let boardArea = CGRect(
            x: content.minX, y: content.minY, width: max(0, column.minX - columnGap - content.minX),
            height: content.height)
        return beside(boardArea: boardArea, column: column, aspect: aspect, fill: fill, chrome: chrome)
    }

    /// Half open like a book: the fold is the boundary. The board takes the
    /// bigger half (the left one when they are equal), the column the other.
    private static func book(
        in safe: CGRect, fold: CGRect, aspect: CGFloat, fill: Bool, chrome: (CGFloat) -> Chrome
    ) -> GameScreenGeometry {
        let content = shrink(safe, by: margin)
        let left = CGRect(
            x: content.minX, y: content.minY, width: max(0, fold.minX - margin - content.minX),
            height: content.height)
        let rightX = fold.maxX + margin
        let right = CGRect(x: rightX, y: content.minY, width: max(0, content.maxX - rightX), height: content.height)
        let (boardArea, column) = left.width >= right.width ? (left, right) : (right, left)
        return beside(boardArea: boardArea, column: column, aspect: aspect, fill: fill, chrome: chrome)
    }

    /// Side by side, given where the board and the column go.
    private static func beside(
        boardArea: CGRect, column: CGRect, aspect: CGFloat, fill: Bool, chrome: (CGFloat) -> Chrome
    ) -> GameScreenGeometry {
        let board = fit(aspect: aspect, width: boardArea.width, height: boardArea.height)
        let boardFrame = CGRect(
            x: boardArea.midX - board.width / 2, y: boardArea.midY - board.height / 2, width: board.width,
            height: board.height)
        // The opponent at the top, the player at the bottom (each next to
        // their side of the board), the rest between.
        let rows = chrome(column.width)
        let playerRow = CGRect(
            x: column.minX, y: column.maxY - rows.playerRow, width: column.width, height: rows.playerRow)
        let (topBar, details, chatRoom) = panel(in: column, above: playerRow.minY, rows: rows, fill: fill)
        return GameScreenGeometry(
            arrangement: .sideBySide, boardSize: board, panelWidth: column.width,
            frames: Frames(topBar: topBar, board: boardFrame, playerRow: playerRow, details: details),
            chatRoom: chatRoom)
    }

    /// Half open with the fold across: the board and the player's row on the
    /// lower half, the opponent and the details on the upper one.
    private static func tabletop(
        in safe: CGRect, fold: CGRect, aspect: CGFloat, fill: Bool, chrome: (CGFloat) -> Chrome
    ) -> GameScreenGeometry {
        let content = shrink(safe, by: margin)
        let width = content.width
        let rows = chrome(width)
        let upper = CGRect(
            x: content.minX, y: content.minY, width: width, height: max(0, fold.minY - margin - content.minY))
        let lowerY = fold.maxY + margin
        let lower = CGRect(x: content.minX, y: lowerY, width: width, height: max(0, content.maxY - lowerY))

        // The board right under the fold, edge to edge as when stacked, the
        // player's row under it, nearest the player.
        let board = fit(aspect: aspect, width: safe.width, height: lower.height - rows.playerRow - spacing)
        let boardFrame = CGRect(
            x: safe.midX - board.width / 2, y: lower.minY, width: board.width, height: board.height)
        let playerRow = CGRect(x: content.minX, y: boardFrame.maxY + spacing, width: width, height: rows.playerRow)

        // The upper half, held up facing the player: a column with no
        // player's row at the bottom; the fold ends it.
        let (topBar, details, chatRoom) = panel(in: upper, above: nil, rows: rows, fill: fill)
        return GameScreenGeometry(
            arrangement: .tabletop, boardSize: board, panelWidth: width,
            frames: Frames(topBar: topBar, board: boardFrame, playerRow: playerRow, details: details),
            chatRoom: chatRoom)
    }

    /// The opponent's row at the top of `area`, then the details down to
    /// `above` (the player's row) or to the bottom of `area`: all that
    /// height with `fill`, otherwise their own height, centred in it. Also
    /// gives the height left there for an inline chat. Nothing leaves `area`
    /// at the bottom, even when it is too short.
    private static func panel(
        in area: CGRect, above: CGFloat?, rows: Chrome, fill: Bool
    ) -> (topBar: CGRect, details: CGRect, chatRoom: CGFloat) {
        let topBar = CGRect(x: area.minX, y: area.minY, width: area.width, height: min(rows.topBar, area.height))
        let top = topBar.maxY + spacing
        let bottom = above.map { $0 - spacing } ?? area.maxY
        let space = max(0, bottom - top)
        let height = fill ? space : min(space, rows.details)
        let details = CGRect(
            x: area.minX, y: min(top + (space - height) / 2, area.maxY), width: area.width, height: height)
        // Under the details: the space between them and the chat, then the chat.
        return (topBar, details, max(0, space - rows.details - spacing))
    }

    /// `rect` less `inset` on every side, never smaller than nothing (unlike
    /// `CGRect.insetBy`, which turns a too-small rectangle into `.null`).
    private static func shrink(_ rect: CGRect, by inset: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX + min(inset, rect.width / 2), y: rect.minY + min(inset, rect.height / 2),
            width: max(0, rect.width - 2 * inset), height: max(0, rect.height - 2 * inset))
    }

    /// The part of `rect` inside `bounds`, or nil if none. A fold may be a
    /// line with no thickness, so a zero width or height still counts
    /// (`CGRect.intersection` would call that empty).
    static func clip(_ rect: CGRect, to bounds: CGRect) -> CGRect? {
        let minX = max(rect.minX, bounds.minX)
        let maxX = min(rect.maxX, bounds.maxX)
        let minY = max(rect.minY, bounds.minY)
        let maxY = min(rect.maxY, bounds.maxY)
        guard minX <= maxX, minY <= maxY, !rect.isNull, !rect.isInfinite else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Whether `a` and `b` share some area (touching edges do not count).
    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY
    }
}
