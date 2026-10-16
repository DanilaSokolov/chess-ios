import ChessClient
import ChessCore
import ChessModels
import ChessNet
import SwiftUI

/// A game in progress or just finished.
struct GameView: View {
    @Environment(GameModel.self) private var model
    let game: GameSession

    // The value types below are `nonisolated`: `Screen` is made off the main
    // actor, in `onGeometryChange`, and SwiftUI compares all of them
    // (`onChange`, `onGeometryChange`) wherever it likes.

    /// What the screen offers: its size, and the parts of it the hardware
    /// takes (the fold of an iPhone Duo, the camera, the Dynamic Island), in
    /// the game screen's own coordinates.
    private nonisolated struct Screen: Equatable, Sendable {
        var size = CGSize.zero
        var fold: CGRect?
        var occlusions: [CGRect] = []

        init() {}

        init(_ proxy: GeometryProxy) {
            size = proxy.size
            // iOS only: the macOS 27.0 SDK has no reserved regions at all, so
            // `#available` alone would not compile there.
            #if os(iOS)
                if #available(iOS 27.1, *) {
                    // Active regions only: the fold while it divides the screen,
                    // the camera while it is in the way.
                    fold = proxy.reservedRegions(kind: .division).first { $0.isActive }?.frame
                    occlusions = proxy.reservedRegions(kind: .occlusion).filter { $0.isActive }.map { $0.frame }
                }
            #endif
        }
    }

    /// The heights of the rows around the board, measured on screen. The
    /// arrangement is decided from them; `GameLayout` then sizes the board
    /// from the rows themselves. Until the rows are on screen: about what
    /// they take (`Chrome.estimate`).
    ///
    /// Why not decide in the layout, which measures them anyway: the chat,
    /// inline or a button, is part of the views, so the decision has to come
    /// before layout, as state.
    ///
    /// An approximation remains: each row is measured at the width it has
    /// now, and that width depends on the arrangement (the column is narrower
    /// than the screen, so text there can wrap onto more lines). Side by side,
    /// stacked is judged with the rows as tall as they are in the column; so
    /// the error favours the arrangement on screen, which can widen the
    /// hysteresis a little when text wraps but cannot make the screen flip
    /// back and forth. Just after a switch to side by side, the chat's room is
    /// judged with the rows at the full width for a moment, then again at the
    /// column's width: the chat can change its mind once, no more (it is not
    /// part of what is measured).
    private nonisolated struct Rows: Equatable, Sendable {
        var topBar = GameScreenGeometry.Chrome.estimate.topBar
        var playerRow = GameScreenGeometry.Chrome.estimate.playerRow
        /// Status, notices, moves and buttons: the details without the chat.
        var details = GameScreenGeometry.Chrome.estimate.details
        /// The chat button alone, as last seen (it is gone while the chat is
        /// inline, and kept for when stacked is considered again).
        var chatButton = GameScreenGeometry.Chrome.estimate.chatButton - GameScreenGeometry.spacing

        var chrome: GameScreenGeometry.Chrome {
            GameScreenGeometry.Chrome(
                topBar: topBar, playerRow: playerRow, details: details,
                chatButton: chatButton + GameScreenGeometry.spacing)
        }
    }

    /// The screen's shape, decided here once: the layout places everything
    /// by it, and the chat goes inline or stays a button by it. It carries
    /// the board's shape, the fold, the hinge and the regions it was decided
    /// with, so the layout never mixes a new fold with an old arrangement,
    /// and a change in any of them animates as one.
    private nonisolated struct Shape: Equatable, Sendable {
        var arrangement = GameScreenGeometry.Arrangement.stacked
        var chatInline = false
        var boardAspect: CGFloat = 1
        var fold: CGRect?
        var hinge = GameScreenGeometry.HingePose.none
        var occlusions: [CGRect] = []
    }

    /// Everything the shape is decided from.
    private nonisolated struct Inputs: Equatable, Sendable {
        var screen: Screen
        var hinge: GameScreenGeometry.HingePose
        var rows: Rows
        var boardAspect: CGFloat
    }

    @State private var screen = Screen()
    /// `.none` until the system reports the hinge (see `HingeTracking`).
    @State private var hinge = GameScreenGeometry.HingePose.none
    @State private var rows = Rows()
    @State private var shape = Shape()

    var body: some View {
        let boardAspect = model.settings.prefersBoard3D ? BoardScene.viewAspect : 1
        let inputs = Inputs(screen: screen, hinge: hinge, rows: rows, boardAspect: boardAspect)
        // Stacked on a phone, side by side on a wide screen, whichever gives
        // the board more room, or split by the fold of a half-open iPhone Duo;
        // the same four views every way, so the board is not rebuilt when the
        // screen changes shape (see GameLayout).
        GameLayout(
            arrangement: shape.arrangement, boardAspect: shape.boardAspect, detailsFillColumn: shape.chatInline,
            fold: shape.fold, hinge: shape.hinge, occlusions: shape.occlusions
        ) {
            topBar
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rows.topBar = $0 }
            boardWithAnnouncement
            myRow
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rows.playerRow = $0 }
            details
        }
        .onGeometryChange(for: Screen.self) { Screen($0) } action: { screen = $0 }
        .modifier(HingeTracking(pose: $hinge))
        .onChange(of: inputs, initial: true) { _, inputs in
            decide(inputs)
        }
        // Inline, the chat is on screen: it counts as open, so its messages
        // are read. Back to a button, it closes rather than pop up as a sheet.
        .onChange(of: shape.chatInline, initial: true) { _, inline in
            model.isChatOpen = inline
        }
        .gameFullScreen(keepsAwake: !game.isOver)
        .onChange(of: game.moves.count) { old, new in
            // One new move by the opponent: say it, or a VoiceOver user would not
            // know the board changed. (A jump of several moves is a resumed game.)
            guard new == old + 1, let move = game.moves.last, game.isMyTurn,
                let piece = game.position[move.to]
            else { return }
            AccessibilityNotification.Announcement(
                BoardDescription.opponentMove(move, piece: piece, givesCheck: game.position.isInCheck)
            ).post()
        }
        .sheet(
            isPresented: Binding(
                get: { model.isChatOpen && !shape.chatInline },
                // The sheet closing because the chat went inline must not close the chat.
                set: { if !shape.chatInline { model.isChatOpen = $0 } })
        ) {
            ChatView()
                .presentationDetents([.medium, .large])
        }
    }

    /// Decides the shape from what the screen offers and the rows measured,
    /// keeping the arrangement on screen unless another is clearly better
    /// (`GameScreenGeometry.switchMargin`), and animates the change: a
    /// rotation, a resize, unfolding or bending an iPhone Duo.
    private func decide(_ inputs: Inputs) {
        let chrome = inputs.rows.chrome
        let plan = GameScreenGeometry.plan(
            in: inputs.screen.size, boardAspect: inputs.boardAspect, current: shape.arrangement,
            fold: inputs.screen.fold, hinge: inputs.hinge, occlusions: inputs.screen.occlusions
        ) { _ in chrome }
        let new = Shape(
            arrangement: plan.arrangement, chatInline: plan.hasRoomForInlineChat, boardAspect: inputs.boardAspect,
            fold: inputs.screen.fold, hinge: inputs.hinge, occlusions: inputs.screen.occlusions)
        guard new != shape else { return }
        withAnimation(.smooth) { shape = new }
    }

    /// The opponent, and how the board is shown.
    private var topBar: some View {
        @Bindable var settings = model.settings
        return HStack {
            PlayerRow(game: game, side: game.color.opponent, name: game.state.opponent)
            Picker("Board", selection: $settings.prefersBoard3D) {
                Text(verbatim: "2D").tag(false)
                Text(verbatim: "3D").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if settings.prefersBoard3D {
                Menu {
                    Toggle("Faceted pieces (8 sides)", isOn: $settings.prefersFacetedPieces)
                    if let reason = simplifiedReason {
                        Section {
                            Text(reason)
                        }
                    }
                } label: {
                    // A thermometer instead of the cube says the picture is simplified.
                    Image(systemName: simplifiedReason == nil ? "cube" : "thermometer.medium")
                }
                .accessibilityLabel("Piece style")
                .accessibilityValue(simplifiedReason.map { Text($0) } ?? Text(verbatim: ""))
                .fixedSize()
            }
        }
    }

    /// Why the 3D board is drawn with less detail, if it is.
    private var simplifiedReason: LocalizedStringKey? {
        let power = model.power
        return switch power.quality {
        case .full: nil
        case .reduced where power.thermalState == .serious: "Simplified 3D: the device is warm"
        case .reduced: "Simplified 3D: Low Power Mode"
        case .minimal: "Simplified 3D: the device is hot"
        }
    }

    private var myRow: some View {
        PlayerRow(game: game, side: game.color, name: model.displayName ?? String(localized: "You"))
    }

    /// Status, notices, moves, actions and chat.
    private var details: some View {
        VStack(spacing: GameScreenGeometry.spacing) {
            // Short of height (stacked in a small window or Split View, the
            // largest text), the layout offers the details only what is left
            // under the player's row: then they scroll rather than overflow.
            ViewThatFits(in: .vertical) {
                detailsContent
                ScrollView(.vertical) { detailsContent }
            }
            // Served first: the inline chat takes the height that is left.
            .layoutPriority(1)
            if shape.chatInline {
                InlineChat()
            } else {
                ChatButton()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rows.chatButton = $0 }
            }
        }
    }

    /// The details without the chat. Measured for `rows` at its own height,
    /// in the scroll view too: a squeezed screen must not make the details
    /// look shorter than they are, or the next decision would be made with
    /// the squeezed height.
    private var detailsContent: some View {
        VStack(spacing: 10) {
            banners
            Text(status).font(.headline)
            if let error = model.state.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            MoveList(moves: game.moves)
            controls
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rows.details = $0 }
    }

    /// The board takes all the room it is given; "the game has begun" sits over
    /// the opponent's side of it, wherever the board is.
    private var boardWithAnnouncement: some View {
        board
            .overlay {
                if let ends = model.state.startAnnouncementEnds {
                    GeometryReader { boardArea in
                        // Placed by layout, not `.offset`: the travelling label animates
                        // between laid-out frames, and an offset would make it jump at the end.
                        StartAnnouncement(ends: ends) { model.dismissStartAnnouncement() }
                            .frame(maxWidth: .infinity)
                            .padding(.top, boardArea.size.height * 0.18)
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                }
            }
    }

    @ViewBuilder
    private var board: some View {
        let interactive = game.isMyTurn && model.connection == .online
        let play: (Move) -> Void = { move in Task { await model.play(move) } }
        if model.settings.prefersBoard3D {
            Board3DView(
                position: game.position, perspective: game.color, lastMove: game.moves.last,
                isInteractive: interactive,
                pieceSegments: model.pieceSegments, quality: model.power.quality,
                onMove: play)
        } else {
            BoardView(
                position: game.position, perspective: game.color, lastMove: game.moves.last,
                isInteractive: interactive, onMove: play)
        }
    }

    @ViewBuilder
    private var banners: some View {
        if case .reconnecting(let attempt) = model.connection {
            Banner(systemImage: "wifi.exclamationmark", tint: .orange) {
                Text("Reconnecting… (attempt \(attempt))")
            }
        }
        if let deadline = game.opponentDeadline, !game.isOver {
            Banner(systemImage: "person.crop.circle.badge.exclamationmark", tint: .orange) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, Int(deadline.timeIntervalSince(context.date).rounded(.up)))
                    Text("Your opponent disconnected. You win if they are not back in \(left) s")
                }
            }
        }
        if game.state.drawOfferedBy == game.color.opponent, !game.isOver {
            Banner(systemImage: "equal.circle", tint: .blue) {
                HStack {
                    Text("Your opponent offers a draw")
                    Spacer()
                    Button("Accept") { Task { await model.offerDraw() } }
                        .buttonStyle(.borderedProminent)
                    Button("Decline") { Task { await model.declineDraw() } }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        if game.isOver {
            Button(model.state.room == nil ? "To the lobby" : "To the room") { model.dismissFinishedGame() }
                .buttonStyle(.borderedProminent)
        } else {
            HStack {
                Button(game.state.drawOfferedBy == game.color ? "Draw offered" : "Offer a draw") {
                    Task { await model.offerDraw() }
                }
                .disabled(game.state.drawOfferedBy != nil || model.connection != .online)
                Button("Resign", role: .destructive) {
                    Task { await model.resign() }
                }
                .disabled(model.connection != .online)
            }
            .buttonStyle(.bordered)
        }
    }

    private var status: String {
        if let outcome = game.outcome {
            return "\(resultText(outcome.result, for: game.color)) · \(outcome.termination.text)"
        }
        let check = game.position.isInCheck ? String(localized: "Check! ") : ""
        return check + (game.isMyTurn ? String(localized: "Your move") : String(localized: "Opponent's move"))
    }
}

/// The chat in the column beside the board, on a wide screen, as Telegram on
/// an iPad keeps it beside the chat list: no sheet to open and close.
private struct InlineChat: View {
    @Environment(GameModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.state.chatPartner ?? String(localized: "Chat"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                MuteButton()
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            ChatPanel()
        }
        .frame(maxHeight: .infinity)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Keeps `pose` up to date with the hinge of a foldable (iPhone Duo), where
/// the system reports one: iOS 27.1 on.
///
/// `onHingeChange` reports changes; until the first one the pose stays
/// `.none`, and the geometry goes by the fold alone: an active fold means
/// half open (see `GameScreenGeometry.plan`).
///
/// The `if #available` is decided once for the life of the app and never
/// switches branch, so unlike an `if` on the screen's shape it does not
/// rebuild the board.
private struct HingeTracking: ViewModifier {
    @Binding var pose: GameScreenGeometry.HingePose

    func body(content: Content) -> some View {
        // iOS only: the macOS 27.0 SDK has no hinge API (see `Screen`).
        #if os(iOS)
            if #available(iOS 27.1, *) {
                content.onHingeChange { _, new in
                    pose = GameScreenGeometry.HingePose(new)
                }
            } else {
                content
            }
        #else
            content
        #endif
    }
}

#if os(iOS)
@available(iOS 27.1, *)
extension GameScreenGeometry.HingePose {
    /// SwiftUI's hinge as the plain value the geometry works with. A status
    /// this code does not know counts as fully open: the flat layout.
    init(_ context: DeviceHingeContext) {
        guard let hinge = context.hinge else {
            self = .none
            return
        }
        if hinge.status == .closed {
            self = .closed
        } else if hinge.status == .partiallyOpen {
            self = .partiallyOpen
        } else {
            self = .fullyOpen
        }
    }
}
#endif

private struct PlayerRow: View {
    let game: GameSession
    let side: PieceColor
    let name: String

    private var isToMove: Bool { !game.isOver && game.position.sideToMove == side }

    var body: some View {
        HStack {
            Circle()
                .fill(side == .white ? Color.white : Color.black)
                .overlay(Circle().stroke(.secondary))
                .frame(width: 14, height: 14)
            Text(name).font(.subheadline.weight(isToMove ? .bold : .regular))
            Spacer()
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                ClockText(remaining: game.remaining(side, at: context.date), isRunning: isToMove)
            }
        }
    }
}

private struct ClockText: View {
    let remaining: Duration
    let isRunning: Bool

    var body: some View {
        Text(formatted)
            .font(.title3.monospacedDigit().weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                isRunning ? (isLow ? Color.red : Color.accentColor) : Color.secondary.opacity(0.15),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .foregroundStyle(isRunning ? Color.white : Color.primary)
    }

    private var isLow: Bool { remaining < .seconds(20) }

    /// m:ss, with tenths under 20 seconds.
    private var formatted: String {
        let tenths = Int(remaining.seconds * 10)
        let minutes = tenths / 600
        let seconds = tenths / 10 % 60
        if isLow {
            return String(format: "%d:%02d.%d", minutes, seconds, tenths % 10)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private struct Banner<Content: View>: View {
    let systemImage: String
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        HStack {
            Image(systemName: systemImage).foregroundStyle(tint)
            content.font(.subheadline)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct MoveList: View {
    let moves: [Move]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(stride(from: 0, to: moves.count, by: 2)), id: \.self) { i in
                        let black = i + 1 < moves.count ? " \(moves[i + 1].uci)" : ""
                        Text(verbatim: "\(i / 2 + 1). \(moves[i].uci)\(black)")
                            .font(.caption.monospaced())
                            .id(i)
                    }
                }
            }
            .onChange(of: moves.count) {
                proxy.scrollTo(max(0, (moves.count - 1) / 2 * 2), anchor: .trailing)
            }
        }
        .frame(height: 20)
    }
}
