import CoreGraphics
import Testing

@testable import ChessClient

private typealias Geometry = GameScreenGeometry

/// About what the game screen's rows take: a clock row, a status line, the
/// moves, the buttons and the chat button.
private func chrome(_: CGFloat) -> GameScreenGeometry.Chrome {
    .init(topBar: 36, playerRow: 36, details: 150)
}

private func plan(
    _ width: CGFloat, _ height: CGFloat, current: GameScreenGeometry.Arrangement? = nil
) -> GameScreenGeometry {
    GameScreenGeometry.plan(in: CGSize(width: width, height: height), current: current, chrome: chrome)
}

/// All four frames of a plan, to check them together.
private func allFrames(_ plan: GameScreenGeometry) -> [CGRect] {
    [plan.frames.topBar, plan.frames.board, plan.frames.playerRow, plan.frames.details]
}

@Test func aPhoneStacksAndTheBoardTakesTheWidth() {
    let p = plan(440, 956)  // iPhone 18 Pro Max, portrait
    #expect(p.arrangement == .stacked)
    #expect(p.boardSize.width == 440, "edge to edge")
}

/// With room to spare, the details sit at the bottom at their own height,
/// below the player's row.
@Test func stackedTheDetailsSitAtTheBottom() {
    let p = plan(440, 956)
    #expect(p.frames.details == CGRect(x: 16, y: 956 - 16 - 150, width: 408, height: 150))
    #expect(p.frames.details.minY > p.frames.playerRow.maxY)
    #expect(p.frames.playerRow.minY == p.frames.board.maxY + Geometry.spacing, "the rows hug the board")
}

@Test func aWideScreenPutsTheBoardBesideTheRest() {
    let p = plan(1366, 1024)  // a large iPad on its side
    #expect(p.arrangement == .sideBySide)
    #expect(p.boardSize.width == CGFloat(1366 - 32 - 24 - 380), "the column limits it, not the height")
    #expect(p.panelWidth == 380)
    #expect(p.frames.board.maxX + Geometry.columnGap <= p.frames.topBar.minX, "the board left of the column")
}

@Test func aTallIPadStacks() {
    #expect(plan(1024, 1366).arrangement == .stacked)
}

/// An unfolded foldable is nearly square. Neither "is it landscape" nor the
/// device decides: the board is bigger stacked here, so it stacks.
@Test func aNearlySquareScreenTakesTheBiggerBoard() {
    let square = plan(900, 820)
    let stackedBoard = 820 - 2 * 16 - 36 - 36 - 150 - 3 * 10 - 8
    #expect(square.arrangement == .stacked)
    #expect(square.boardSize.height == CGFloat(stackedBoard))
}

/// A phone on its side (compact × compact): side by side, the board as tall as the screen allows.
@Test func aPhoneOnItsSideGoesSideBySide() {
    let p = plan(956, 440)
    #expect(p.arrangement == .sideBySide)
    #expect(p.boardSize.height == CGFloat(440 - 2 * 16))
}

/// Near the point where both give the same board, stacked holds on.
@Test func aTieStaysStacked() throws {
    // Find a width where side by side wins by less than the margin.
    let height: CGFloat = 820
    let close = stride(from: 900, through: 1400, by: 1).map { CGFloat($0) }.first { width in
        let column = GameScreenGeometry.columnWidth(for: width)
        let side = min(height - 32, width - 32 - 24 - column)
        let stacked = min(width, height - 32 - 222 - 30 - 8)
        return side > stacked && side <= stacked * GameScreenGeometry.switchMargin
    }
    let width = try #require(close)
    #expect(plan(width, height).arrangement == .stacked)
}

/// Side by side's board over stacked's, at `width` × 820.
private func sideOverStacked(_ width: CGFloat) -> CGFloat {
    let size = CGSize(width: width, height: 820)
    let side = Geometry.plan(in: size, arrangement: .sideBySide, chrome: chrome).boardSize.width
    let stacked = Geometry.plan(in: size, arrangement: .stacked, chrome: chrome).boardSize.width
    return side / stacked
}

/// Inside the ±5% band around a tie, whatever is on screen stays: a window
/// dragged back and forth there does not flip.
@Test func withinTheBandTheCurrentArrangementStays() throws {
    let band = stride(from: 800, through: 1200, by: 1).map { CGFloat($0) }.filter { width in
        let ratio = sideOverStacked(width)
        return ratio > 1 / Geometry.switchMargin && ratio < Geometry.switchMargin
    }
    try #require(!band.isEmpty)
    for width in band {
        #expect(plan(width, 820, current: .stacked).arrangement == .stacked)
        #expect(plan(width, 820, current: .sideBySide).arrangement == .sideBySide)
    }
}

/// A window resized back and forth across the band: it switches once on
/// leaving the band, not on every crossing of the tie.
@Test func leavingTheBandSwitches() {
    // At 820 high: 940 and 960 are inside the band, 900 below it, 1000 above.
    #expect(sideOverStacked(900) < 1 / Geometry.switchMargin)
    #expect(sideOverStacked(1000) > Geometry.switchMargin)
    var current = GameScreenGeometry.Arrangement.stacked
    var seen: [GameScreenGeometry.Arrangement] = []
    for width: CGFloat in [940, 960, 1000, 960, 940, 900, 940, 960] {
        current = plan(width, 820, current: current).arrangement
        seen.append(current)
    }
    #expect(
        seen == [
            .stacked, .stacked, .sideBySide, .sideBySide, .sideBySide, .stacked, .stacked, .stacked,
        ])
}

@Test func nothingGoesNegative() {
    let p = plan(10, 10)
    #expect(p.boardSize.width >= 0 && p.boardSize.height >= 0)
    #expect(p.panelWidth >= 0)
    for frame in allFrames(p) {
        #expect(frame.width >= 0 && frame.height >= 0)
    }
}

/// Too short for the rows and a full board (a small window, Split View,
/// the largest text): the board keeps a playable size, and the details get
/// what is left under the player's row, never sliding up over it.
@Test func aShortScreenKeepsAPlayableBoard() {
    let p = GameScreenGeometry.plan(in: CGSize(width: 440, height: 400), arrangement: .stacked, chrome: chrome)
    #expect(p.boardSize == CGSize(width: Geometry.minBoard, height: Geometry.minBoard))
    // Top bar 16...52, board 62...262, player's row 272...308, details from 326 to 400 - 16.
    #expect(p.frames.details == CGRect(x: 16, y: 326, width: 408, height: 58))
    #expect(p.frames.details.minY >= p.frames.playerRow.maxY)
}

@Test func withNoRoomAtAllTheDetailsShrinkToNothingBelowThePlayer() {
    let p = GameScreenGeometry.plan(in: CGSize(width: 440, height: 250), arrangement: .stacked, chrome: chrome)
    #expect(p.boardSize.width == Geometry.minBoard)
    #expect(p.frames.details.height == 0)
    #expect(p.frames.details.minY >= p.frames.playerRow.maxY)
}

/// The least board is never wider than the screen.
@Test func theLeastBoardFitsANarrowScreen() {
    let p = GameScreenGeometry.plan(in: CGSize(width: 150, height: 300), arrangement: .stacked, chrome: chrome)
    #expect(p.boardSize.width == 150)
}

/// The 3D board is wider than tall: stacked on a phone it takes the full
/// width and less height, so the player's row sits right under it.
@Test func aWideBoardIsShorter() {
    let p = GameScreenGeometry.plan(in: CGSize(width: 440, height: 956), boardAspect: 1.12, chrome: chrome)
    #expect(p.boardSize.width == 440)
    #expect(abs(p.boardSize.height - 440 / 1.12) < 0.001)
}

/// The arrangement can be given: the game screen decides once, and the
/// layout and the chat both follow that one decision.
@Test func aGivenArrangementIsKept() {
    let p = GameScreenGeometry.plan(in: CGSize(width: 440, height: 956), arrangement: .sideBySide, chrome: chrome)
    #expect(p.arrangement == .sideBySide)
}

/// A tabletop asked for with no fold across the screen to split it by is
/// whatever a flat screen would be: on a phone held upright, stacked.
@Test func aTabletopWithoutAFoldStacks() {
    let p = GameScreenGeometry.plan(in: CGSize(width: 440, height: 956), arrangement: .tabletop, chrome: chrome)
    #expect(p.arrangement == .stacked)
}

@Test func theChatGoesInlineOnlyWhenTallEnough() {
    #expect(GameScreenGeometry.fitsInlineChat(in: CGSize(width: 1366, height: 1024)), "an iPad on its side")
    #expect(!GameScreenGeometry.fitsInlineChat(in: CGSize(width: 956, height: 440)), "a phone on its side")
}

// MARK: - The fold

/// An iPhone Duo's inner screen on its side, the fold across it.
private let inner = CGSize(width: 951, height: 669)
private let foldAcross = CGRect(x: 0, y: 330, width: 951, height: 9)
private let foldDown = CGRect(x: 471, y: 0, width: 9, height: 669)

private func folded(
    _ size: CGSize = inner, fold: CGRect?, hinge: GameScreenGeometry.HingePose = .partiallyOpen,
    fill: Bool = false
) -> GameScreenGeometry {
    GameScreenGeometry.plan(in: size, fold: fold, hinge: hinge, detailsFillColumn: fill, chrome: chrome)
}

@Test func halfOpenWithTheFoldAcrossIsATabletop() {
    let p = folded(fold: foldAcross)
    #expect(p.arrangement == .tabletop)
    let f = p.frames
    // Below the fold: the board right under it, the player's row under the board.
    #expect(f.board.minY >= foldAcross.maxY)
    #expect(f.playerRow.minY >= f.board.maxY)
    #expect(f.playerRow.maxY <= inner.height - Geometry.margin)
    // The lower half is 339 + 16 ... 669 - 16: 298 high, less the player's row.
    #expect(f.board.height == 298 - 36 - 10)
    // Above the fold: the opponent, then the details.
    #expect(f.topBar.maxY <= foldAcross.minY)
    #expect(f.details.minY >= f.topBar.maxY)
    #expect(f.details.maxY <= foldAcross.minY)
    for frame in allFrames(p) {
        #expect(!Geometry.overlaps(frame, foldAcross), "nothing in the fold")
    }
    #expect(!p.hasRoomForInlineChat, "half a phone's inner screen is too low for the chat")
}

/// With room above the fold, the chat goes there, and the details take it all.
@Test func aTallTabletopHasTheChatAboveTheFold() {
    let size = CGSize(width: 1366, height: 1024)
    let fold = CGRect(x: 0, y: 507, width: 1366, height: 10)
    let p = folded(size, fold: fold)
    #expect(p.arrangement == .tabletop)
    #expect(p.hasRoomForInlineChat)
    let filled = folded(size, fold: fold, fill: true)
    #expect(filled.frames.details.maxY == fold.minY - Geometry.margin)
    #expect(!Geometry.overlaps(filled.frames.details, fold))
}

@Test func halfOpenWithTheFoldDownIsABook() {
    let p = folded(fold: foldDown)
    #expect(p.arrangement == .sideBySide)
    let f = p.frames
    // Two equal halves: the board on the left, the column on the right; the fold between.
    #expect(f.board.maxX <= foldDown.minX)
    for row in [f.topBar, f.playerRow, f.details] {
        #expect(row.minX >= foldDown.maxX)
    }
    #expect(p.panelWidth == 951 - 16 - (471 + 9 + 16))
    #expect(p.boardSize.width == 471 - 16 - 16, "the board fills its half")
    for frame in allFrames(p) {
        #expect(!Geometry.overlaps(frame, foldDown), "nothing in the fold")
    }
}

/// A fold off the middle: the board takes the bigger side.
@Test func inABookTheBoardTakesTheBiggerSide() {
    let fold = CGRect(x: 300, y: 0, width: 9, height: 669)
    let p = folded(fold: fold)
    #expect(p.arrangement == .sideBySide)
    #expect(p.frames.board.minX >= fold.maxX)
    for row in [p.frames.topBar, p.frames.playerRow, p.frames.details] {
        #expect(row.maxX <= fold.minX)
    }
}

/// Flat or closed, the fold changes nothing: the board may run across it,
/// as it does on a flat screen.
@Test func aFlatFoldChangesNothing() {
    let flat = folded(fold: nil, hinge: .none)
    for hinge: GameScreenGeometry.HingePose in [.closed, .fullyOpen] {
        #expect(folded(fold: foldAcross, hinge: hinge) == flat)
        #expect(folded(fold: foldDown, hinge: hinge) == flat)
    }
    #expect(folded(fold: nil) == flat, "half open, but no fold on this screen")
    #expect(folded(fold: CGRect(x: 0, y: 2000, width: 951, height: 9)) == flat, "a fold off this screen")
}

/// Before the hinge has reported anything (`onHingeChange` reports only
/// changes), an active fold alone means half open: a game opened on a device
/// already standing as a tabletop starts as one.
@Test func anActiveFoldBeforeTheHingeReportsCountsAsHalfOpen() {
    #expect(folded(fold: foldAcross, hinge: .none) == folded(fold: foldAcross, hinge: .partiallyOpen))
    #expect(folded(fold: foldAcross, hinge: .none).arrangement == .tabletop)
    #expect(folded(fold: foldDown, hinge: .none) == folded(fold: foldDown, hinge: .partiallyOpen))
}

/// Mid-rotation, the layout can get the new size before the new fold: a
/// tabletop asked for with the old fold, now off the screen or running down
/// it. The stale fold is ignored and the screen is laid out as a flat one of
/// that size, side by side here, not dropped to stacked for a frame.
@Test func aTabletopWithAStaleFoldFallsBackToTheFlatChoice() {
    let flatWide = GameScreenGeometry.plan(in: inner, arrangement: .sideBySide, chrome: chrome)
    #expect(flatWide.arrangement == .sideBySide)
    // A fold across the screen as it was (taller than this one), below its bottom edge now.
    let offScreen = GameScreenGeometry.plan(
        in: inner, arrangement: .tabletop, fold: CGRect(x: 0, y: 700, width: 669, height: 9),
        hinge: .partiallyOpen, chrome: chrome)
    #expect(offScreen == flatWide)
    // A fold that runs down the screen does not split a tabletop either.
    let down = GameScreenGeometry.plan(
        in: inner, arrangement: .tabletop, fold: foldDown, hinge: .partiallyOpen, chrome: chrome)
    #expect(down == flatWide)
    // Upright, the flat choice is stacked, as before.
    let upright = GameScreenGeometry.plan(
        in: CGSize(width: 669, height: 951), arrangement: .tabletop, fold: foldDown, hinge: .partiallyOpen,
        chrome: chrome)
    #expect(upright.arrangement == .stacked)
}

/// Halves too small for anything: sizes stay at zero or more, and still
/// nothing goes into the fold.
@Test func tinyHalvesDoNotGoNegative() {
    let across = CGRect(x: 0, y: 40, width: 300, height: 20)
    let down = CGRect(x: 40, y: 0, width: 20, height: 300)
    let cases = [
        (CGSize(width: 300, height: 100), across),
        (CGSize(width: 100, height: 300), down),
    ]
    for (size, fold) in cases {
        let p = folded(size, fold: fold)
        #expect(p.boardSize.width >= 0 && p.boardSize.height >= 0)
        #expect(p.panelWidth >= 0)
        for frame in allFrames(p) {
            #expect(frame.width >= 0 && frame.height >= 0)
            #expect(!Geometry.overlaps(frame, fold))
        }
    }
}

// MARK: - The camera and the Dynamic Island

@Test func theDynamicIslandInsetsTheTopOnly() {
    let bounds = CGRect(x: 0, y: 0, width: 440, height: 956)
    let island = CGRect(x: 157, y: 11, width: 126, height: 37)
    #expect(Geometry.safeArea(of: bounds, avoiding: [island]) == CGRect(x: 0, y: 48, width: 440, height: 908))
}

/// On its side, the camera is on one edge only: that edge moves in, the other does not.
@Test func aCameraOnTheSideInsetsThatSideOnly() {
    let bounds = CGRect(x: 0, y: 0, width: 956, height: 440)
    let left = CGRect(x: 11, y: 157, width: 37, height: 126)
    let right = CGRect(x: 908, y: 157, width: 37, height: 126)
    #expect(Geometry.safeArea(of: bounds, avoiding: [left]) == CGRect(x: 48, y: 0, width: 908, height: 440))
    #expect(Geometry.safeArea(of: bounds, avoiding: [right]) == CGRect(x: 0, y: 0, width: 908, height: 440))
}

/// A window's controls in the corner: cleared from the top, which costs less than the side.
@Test func cornerControlsInsetTheCheaperEdge() {
    let bounds = CGRect(x: 0, y: 0, width: 1024, height: 768)
    let controls = CGRect(x: 8, y: 8, width: 80, height: 28)
    #expect(Geometry.safeArea(of: bounds, avoiding: [controls]) == CGRect(x: 0, y: 36, width: 1024, height: 732))
}

@Test func regionsOffTheScreenChangeNothing() {
    let bounds = CGRect(x: 0, y: 0, width: 440, height: 956)
    let above = CGRect(x: 157, y: -48, width: 126, height: 37)
    #expect(Geometry.safeArea(of: bounds, avoiding: [above]) == bounds)
    #expect(Geometry.safeArea(of: bounds, avoiding: []) == bounds)
}

/// Side by side with the status bar hidden: the camera of a phone on its
/// side, on whichever side it is, has nothing under it.
@Test func nothingGoesUnderTheCamera() {
    let size = CGSize(width: 956, height: 440)
    for camera in [CGRect(x: 11, y: 157, width: 37, height: 126), CGRect(x: 908, y: 157, width: 37, height: 126)] {
        let p = GameScreenGeometry.plan(in: size, occlusions: [camera], chrome: chrome)
        #expect(p.arrangement == .sideBySide)
        for frame in allFrames(p) {
            #expect(!Geometry.overlaps(frame, camera))
        }
    }
}
