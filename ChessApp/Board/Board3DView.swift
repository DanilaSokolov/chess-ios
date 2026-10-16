import ChessClient
import ChessCore
import ChessModels
import RealityKit
import SwiftUI
import os

/// The board in 3D, drawn with RealityKit. Same contract as `BoardView`:
/// tap a piece, then a highlighted square, or drag the piece onto the square;
/// the move goes to `onMove`. Dragging anything else turns the board around,
/// pinching zooms.
/// Pieces come from `ChessModels`: Staunton profiles turned into meshes.
struct Board3DView: View {
    let position: Position
    /// The side the camera looks from.
    let perspective: PieceColor
    var lastMove: Move?
    var isInteractive = true
    /// How finely the pieces are cut around: `PieceModels.smoothSegments`, or 8 to see the facets.
    var pieceSegments = PieceModels.smoothSegments
    /// Lowered while the device is hot; see `RenderQuality`.
    var quality = RenderQuality.full
    var onMove: (Move) -> Void = { _ in }

    @State private var picker = MovePicker()
    @State private var promotionChoices: [Move] = []
    @State private var scene = BoardScene()
    /// The square of the piece being dragged.
    @State private var dragFrom: Square?
    /// The current drag turns the board rather than moving a piece.
    @State private var isOrbiting = false
    /// The view was turned or zoomed: offer to put it back.
    @State private var isViewMoved = false

    var body: some View {
        RealityView { content in
            content.camera = .virtual
            content.add(scene.root)
        } update: { _ in
            scene.show(
                BoardScene.State(
                    position: position,
                    perspective: perspective,
                    pieceSegments: pieceSegments,
                    quality: quality,
                    lastMove: lastMove,
                    selected: picker.selected,
                    targets: picker.targets(from: picker.selected, in: position)
                ))
        }
        .gesture(
            DragGesture(minimumDistance: 4)
                .targetedToAnyEntity()
                .onChanged { value in
                    // The first change decides what this drag is: one of our
                    // pieces on our move is carried, anything else turns the board.
                    if dragFrom == nil, !isOrbiting {
                        if isInteractive, let from = BoardScene.square(of: value.entity),
                            position[from]?.color == position.sideToMove, scene.lift(from)
                        {
                            dragFrom = from
                            picker.selected = from  // Shows its targets.
                        } else {
                            isOrbiting = true
                        }
                    }
                    if isOrbiting {
                        scene.orbit(by: value.translation)
                        isViewMoved = true
                        return
                    }
                    // The point under the finger on the board's surface.
                    guard let ray = value.ray(through: value.location, in: .local, to: .scene),
                        let point = BoardScene.boardPoint(on: ray)
                    else { return }
                    scene.carry(to: point)
                }
                .onEnded { value in
                    if isOrbiting {
                        isOrbiting = false
                        scene.endOrbit()
                        return
                    }
                    guard let from = dragFrom else { return }
                    dragFrom = nil
                    let target = value.ray(through: value.location, in: .local, to: .scene)
                        .flatMap(BoardScene.boardPoint(on:))
                        .flatMap(BoardScene.square(at:))
                    let outcome = picker.drop(from: from, on: target, in: position)
                    // A move leaves the piece where it was dropped; anything else sends it home.
                    scene.drop(staying: outcome != .none)
                    apply(outcome)
                }
        )
        .gesture(
            SpatialTapGesture()
                .targetedToAnyEntity()
                .onEnded { value in
                    guard isInteractive, let square = BoardScene.square(of: value.entity) else { return }
                    apply(picker.tap(square, in: position))
                }
        )
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    scene.zoom(by: value.magnification)
                    isViewMoved = true
                }
                .onEnded { _ in scene.endZoom() }
        )
        .overlay(alignment: .topTrailing) {
            if isViewMoved {
                Button {
                    scene.resetView(animated: true)
                    isViewMoved = false
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .padding(8)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Reset view"))
                .padding(8)
                .transition(.opacity)
            }
        }
        .animation(.default, value: isViewMoved)
        .accessibilityRepresentation {
            AccessibleBoardGrid(
                position: position, perspective: perspective, selected: picker.selected,
                targets: picker.targets(from: picker.selected, in: position), lastMove: lastMove,
                isInteractive: isInteractive
            ) { apply(picker.tap($0, in: position)) }
        }
        .aspectRatio(BoardScene.viewAspect, contentMode: .fit)
        .onChange(of: perspective) { isViewMoved = false }
        .onChange(of: position) {
            picker.selected = nil
            dragFrom = nil
        }
        .promotionDialog($promotionChoices, onMove: onMove)
    }

    private func apply(_ outcome: MovePicker.Outcome) {
        switch outcome {
        case .move(let move): onMove(move)
        case .promotion(let moves): promotionChoices = moves
        case .none: break
        }
    }
}

/// The RealityKit scene behind `Board3DView`. One square is one unit; the
/// board is centered on the origin with White's side towards +z.
@MainActor
final class BoardScene {
    struct State {
        var position: Position
        var perspective: PieceColor
        var pieceSegments: Int
        var quality: RenderQuality
        var lastMove: Move?
        var selected: Square?
        var targets: Set<Square>
    }

    let root = Entity()
    private let pieces = Entity()
    private let markers = Entity()
    private let camera = PerspectiveCamera()
    private let sun = DirectionalLight()
    private var squares: [Square: ModelEntity] = [:]
    private var squareLooks: [Square: Look] = [:]
    /// The piece standing on each square. Kept between moves: a move changes
    /// two to four entries, not all 32 (see `PieceChanges`).
    private var pieceEntities: [Square: Entity] = [:]
    private var shown: State?
    /// The piece following the finger, and where it came from.
    private var carried: (entity: Entity, from: Square)?
    /// The square under the carried piece.
    private var hovered: Square?
    /// Set when a dragged piece made the move: it is already in place, so
    /// the next update does not slide it in again.
    private var skipMoveAnimation = false

    private enum Look: Hashable {
        case plain, lastMove, selected, hovered, check
    }

    /// How high a carried piece floats above the board.
    private static let carryHeight: Float = 0.35

    init() {
        let frame = ModelEntity(
            mesh: .generateBox(width: 8.8, height: 0.3, depth: 8.8, cornerRadius: 0.08),
            materials: [
                SimpleMaterial(
                    color: .init(red: 0.36, green: 0.22, blue: 0.13, alpha: 1), roughness: 0.5, isMetallic: false)
            ]
        )
        frame.position.y = -0.2
        root.addChild(frame)

        let tile = MeshResource.generateBox(width: 1, height: 0.1, depth: 1)
        for square in Square.all {
            let entity = ModelEntity(mesh: tile, materials: [Self.squareMaterial(square, .plain)])
            entity.position = Self.center(of: square) - [0, 0.05, 0]
            entity.name = "sq:\(square.name)"
            entity.components.set(InputTargetComponent())
            entity.components.set(CollisionComponent(shapes: [.generateBox(width: 1, height: 0.1, depth: 1)]))
            squares[square] = entity
            root.addChild(entity)
        }
        root.addChild(pieces)
        root.addChild(markers)

        sun.light.intensity = 2800
        sun.look(at: .zero, from: [3, 10, 5], relativeTo: nil)
        root.addChild(sun)
        let fill = DirectionalLight()
        fill.light.intensity = 900
        fill.look(at: .zero, from: [-4, 6, -6], relativeTo: nil)
        root.addChild(fill)

        // The field of view is set across, not up: on a phone the width is
        // what runs out, and the camera is placed to fill it with the squares.
        camera.camera.fieldOfViewInDegrees = 40
        camera.camera.fieldOfViewOrientation = .horizontal
        root.addChild(camera)

        // An invisible floor far below and around the board, so a drag that
        // starts beside the board still hits something and can turn it.
        let floor = Entity()
        floor.name = "floor"
        floor.position.y = -0.5
        floor.components.set(InputTargetComponent())
        floor.components.set(CollisionComponent(shapes: [.generateBox(width: 200, height: 0.01, depth: 200)]))
        root.addChild(floor)
    }

    // MARK: - Camera
    //
    // The camera circles the board: `yaw` turns it around the vertical axis
    // (0 behind White, π behind Black), `pitch` is its height above the board
    // as an angle, `distance` how far away it is. It looks at a point slightly
    // towards the player, so the near ranks are not cut off.

    /// Steep enough that tall pieces do not hide the rank behind them.
    private static let defaultPitch: Float = atan2(13, 6.8)
    /// Close enough that the eight files fill the view's width from the
    /// default angle; the wooden frame is allowed to run off the sides.
    private static let defaultDistance: Float = 12.6
    /// Width over height of the view: the board seen from the default angle,
    /// with the tallest pieces on the far rank, is a little wider than tall.
    /// Measured by projecting the board's corners for the camera above.
    static let viewAspect: CGFloat = 1.12
    private static let pitchRange: ClosedRange<Float> = 0.35...1.45  // From low over the board to almost straight down.
    private static let distanceRange: ClosedRange<Float> = 8...24
    /// Radians per point dragged.
    private static let orbitSpeed: Float = 0.008

    private var homeYaw: Float = 0
    private var yaw: Float = 0
    private var pitch = defaultPitch
    private var distance = defaultDistance
    /// The camera at the start of the current drag or pinch; gestures report
    /// totals since they began, so changes apply to this, not to the last frame.
    private var orbitStart: (yaw: Float, pitch: Float)?
    private var zoomStart: Float?

    func orbit(by translation: CGSize) {
        let start = orbitStart ?? (yaw, pitch)
        orbitStart = start
        yaw = start.yaw - Float(translation.width) * Self.orbitSpeed
        pitch = (start.pitch + Float(translation.height) * Self.orbitSpeed).clamped(to: Self.pitchRange)
        placeCamera(animated: false)
    }

    func endOrbit() { orbitStart = nil }

    /// `scale` above 1 brings the board closer, as when spreading two fingers.
    func zoom(by scale: CGFloat) {
        let start = zoomStart ?? distance
        zoomStart = start
        distance = (start / Float(max(scale, 0.01))).clamped(to: Self.distanceRange)
        placeCamera(animated: false)
    }

    func endZoom() { zoomStart = nil }

    /// Back to the player's side of the board, at the usual height and distance.
    func resetView(animated: Bool) {
        yaw = homeYaw
        pitch = Self.defaultPitch
        distance = Self.defaultDistance
        placeCamera(animated: animated)
    }

    private func placeCamera(animated: Bool) {
        let target = SIMD3<Float>(sin(yaw), 0, cos(yaw)) * 0.7
        let direction = SIMD3<Float>(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
        if animated {
            var transform = Transform.identity
            transform.translation = target + direction * distance
            // Build the orientation the same way `look(at:)` would, then glide there.
            let probe = Entity()
            probe.look(at: target, from: transform.translation, relativeTo: nil)
            transform.rotation = probe.orientation
            camera.move(to: transform, relativeTo: nil, duration: 0.35, timingFunction: .easeInOut)
        } else {
            camera.look(at: target, from: target + direction * distance, relativeTo: nil)
        }
    }

    /// Brings the scene up to date. Cheap when nothing changed, since SwiftUI
    /// calls it on every update of the view.
    func show(_ state: State) {
        if shown?.perspective != state.perspective {
            homeYaw = state.perspective == .white ? 0 : .pi
            resetView(animated: false)
        }
        if shown?.quality != state.quality {
            // The shadow is a second pass that draws every piece from the light's side.
            sun.shadow = state.quality.hasShadows ? .init(maximumDistance: 20, depthBias: 2) : nil
        }
        if let shown, shown.pieceSegments == state.pieceSegments, shown.quality == state.quality {
            if shown.position != state.position {
                carried = nil
                hovered = nil
                let animate = !skipMoveAnimation
                skipMoveAnimation = false
                updatePieces(from: shown.position, to: state.position, lastMove: state.lastMove, animated: animate)
            }
        } else {
            // First show, or the pieces are cut or lacquered differently: build them all.
            carried = nil
            hovered = nil
            skipMoveAnimation = false
            buildPieces(state.position, segments: state.pieceSegments, quality: state.quality)
        }
        showSquares(state)
        if shown?.targets != state.targets || shown?.position != state.position {
            showTargets(state.targets, on: state.position)
        }
        shown = state
    }

    /// The square an entity (a square or a piece standing on it) stands for.
    static func square(of entity: Entity) -> Square? {
        var e: Entity? = entity
        while let current = e {
            if current.name.hasPrefix("sq:") || current.name.hasPrefix("pc:") {
                return Square(current.name.dropFirst(3))
            }
            e = current.parent
        }
        return nil
    }

    // MARK: - Dragging

    /// Picks up the piece on `square`. Reports false if there is none.
    func lift(_ square: Square) -> Bool {
        guard let entity = pieceEntities[square] else { return false }
        carried = (entity, square)
        return true
    }

    /// Moves the carried piece over `point` on the board.
    func carry(to point: SIMD3<Float>) {
        guard let carried else { return }
        carried.entity.position = [point.x, Self.carryHeight, point.z]
        let square = Self.square(at: point)
        if square != hovered {
            hovered = square
            if let shown { showSquares(shown) }
        }
    }

    /// Lets go of the carried piece. `staying`: it made a move and stays where
    /// it is until the new position arrives; otherwise it glides back.
    func drop(staying: Bool) {
        guard let carried else { return }
        self.carried = nil
        hovered = nil
        if staying {
            skipMoveAnimation = true
            if let square = Self.square(at: carried.entity.position) {
                carried.entity.position = Self.center(of: square)
            }
        } else {
            var home = carried.entity.transform
            home.translation = Self.center(of: carried.from)
            carried.entity.move(to: home, relativeTo: pieces, duration: 0.2, timingFunction: .easeOut)
        }
        if let shown { showSquares(shown) }
    }

    /// Where a ray from the camera meets the board's surface (y = 0).
    static func boardPoint(on ray: (origin: SIMD3<Float>, direction: SIMD3<Float>)) -> SIMD3<Float>? {
        guard ray.direction.y < -1e-4 else { return nil }  // Looking up or along the board.
        let t = -ray.origin.y / ray.direction.y
        return ray.origin + t * ray.direction
    }

    /// The square containing a point of the board, nil off the board.
    static func square(at point: SIMD3<Float>) -> Square? {
        let file = Int((point.x + 4).rounded(.down))
        let rank = Int((4 - point.z).rounded(.down))
        return Square(file: file, rank: rank)
    }

    // MARK: - Pieces

    /// Throws the pieces away and builds every one: on the first show, and when
    /// their cut or material changes.
    private func buildPieces(_ position: Position, segments: Int, quality: RenderQuality) {
        let interval = Signposts.poi.beginInterval("Pieces", id: Signposts.poi.makeSignpostID(), "build all")
        defer { Signposts.poi.endInterval("Pieces", interval) }
        pieceSegments = segments
        pieceClearCoat = quality.hasClearCoat
        pieces.children.removeAll()
        pieceEntities = [:]
        for square in Square.all where position[square] != nil {
            place(makePiece(on: square, in: position), on: square, animated: false)
        }
    }

    /// Changes only what the move changed: the moved pieces slide, captured
    /// ones go, a promoted piece appears. Everything else stays as it is.
    private func updatePieces(from old: Position, to new: Position, lastMove: Move?, animated: Bool) {
        let changes = PieceChanges(from: old, to: new, lastMove: lastMove)
        // An interval in Instruments: how long a move costs the 3D board.
        let interval = Signposts.poi.beginInterval(
            "Pieces", id: Signposts.poi.makeSignpostID(),
            "moved \(changes.moved.count), removed \(changes.removed.count), added \(changes.added.count)")
        defer { Signposts.poi.endInterval("Pieces", interval) }

        for square in changes.removed {
            pieceEntities.removeValue(forKey: square)?.removeFromParent()
        }
        // Take every mover off its square before placing any, so one piece
        // landing where another just left cannot overwrite it.
        let movers = changes.moved.compactMap { move in pieceEntities.removeValue(forKey: move.from).map { (move, $0) }
        }
        for (move, entity) in movers {
            place(entity, on: move.to, animated: animated)
        }
        for square in changes.added {
            let entity = makePiece(on: square, in: new)
            // A promoted piece slides in from the pawn's square.
            if animated, let lastMove, lastMove.to == square {
                entity.position = Self.center(of: lastMove.from)
            }
            place(entity, on: square, animated: animated)
        }
    }

    /// The cut and lacquer the pieces on the board were built with; new pieces match them.
    private var pieceSegments = PieceModels.smoothSegments
    private var pieceClearCoat = true

    private func makePiece(on square: Square, in position: Position) -> Entity {
        let entity = Self.makePiece(position[square]!, segments: pieceSegments, clearCoat: pieceClearCoat)
        pieces.addChild(entity)
        return entity
    }

    /// Puts a piece on `square`, gliding there from where it stands or jumping.
    private func place(_ entity: Entity, on square: Square, animated: Bool) {
        entity.name = "pc:\(square.name)"  // How taps and drags find the square.
        pieceEntities[square] = entity
        entity.stopAllAnimations()  // A slide still running from the previous move.
        var end = entity.transform
        end.translation = Self.center(of: square)
        if animated, entity.position != end.translation {
            entity.move(to: end, relativeTo: pieces, duration: 0.25, timingFunction: .easeInOut)
        } else {
            entity.transform = end
        }
    }

    /// One mesh per kind and cut, shared by both colors and every piece of that kind.
    private struct PieceMesh {
        let body: MeshResource
        let accent: MeshResource?
        let height: Float
        let radius: Float
    }

    private static var meshes: [String: PieceMesh] = [:]

    /// Builds the meshes and materials ahead of time, on the splash screen, so
    /// the first 3D board appears without a pause.
    static func preload(segments: Int, quality: RenderQuality) {
        for kind in PieceKind.allCases {
            _ = mesh(for: kind, segments: segments)
        }
        _ = look(for: .white, clearCoat: quality.hasClearCoat)
    }

    private static func mesh(for kind: PieceKind, segments: Int) -> PieceMesh {
        let key = "\(kind)-\(segments)"
        if let cached = meshes[key] { return cached }
        let interval = Signposts.poi.beginInterval(
            "Piece mesh", id: Signposts.poi.makeSignpostID(), "\(key, privacy: .public)")
        defer { Signposts.poi.endInterval("Piece mesh", interval) }
        let data = PieceModels.mesh(for: kind, segments: segments)
        let (lo, hi) = data.bounds
        let entry = PieceMesh(
            body: resource(data, name: key),
            accent: PieceModels.accent(for: kind).map { resource($0, name: key + "-accent") },
            height: hi.y,
            radius: max(-lo.x, hi.x, -lo.z, hi.z)
        )
        meshes[key] = entry
        return entry
    }

    /// ChessModels builds plain arrays; MeshDescriptor hands them to RealityKit.
    private static func resource(_ data: MeshData, name: String) -> MeshResource {
        var descriptor = MeshDescriptor(name: name)
        descriptor.positions = MeshBuffer(data.positions)
        descriptor.normals = MeshBuffer(data.normals)
        // RealityKit's v runs the other way from ours; flipping keeps the grain the same as in wood.png.
        descriptor.textureCoordinates = MeshBuffer(data.uvs.map { [$0.x, 1 - $0.y] })
        descriptor.primitives = .triangles(data.indices)
        do {
            return try MeshResource.generate(from: [descriptor])
        } catch {
            // ChessModelsTests check every mesh, so this is a bug there. Stop in
            // debug builds; in release show a box rather than end someone's game.
            assertionFailure("Piece mesh \(name) rejected: \(error)")
            return .generateBox(size: 0.5)
        }
    }

    /// The grain from `WoodTexture`, uploaded once. Repeating, so texture
    /// coordinates beyond 1 tile the image instead of smearing its edge.
    private static func makeWood() -> MaterialParameters.Texture? {
        let size = 512
        var pixels = WoodTexture.pixels(size: size)
        let image = pixels.withUnsafeMutableBytes { raw in
            CGContext(
                data: raw.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
        }
        guard let image, let texture = try? TextureResource(image: image, options: .init(semantic: .color)) else {
            return nil
        }
        let sampler = MTLSamplerDescriptor()
        sampler.sAddressMode = .repeat
        sampler.tAddressMode = .repeat
        sampler.minFilter = .linear
        sampler.magFilter = .linear
        sampler.mipFilter = .linear
        return .init(texture, sampler: .init(sampler))
    }

    /// Lacquered wood: the grain tinted ivory or ebony, physically based, with
    /// a clear coat that catches highlights. The accent (the bishop's slit) is
    /// a contrasting matte colour.
    private struct PieceLook {
        let body: PhysicallyBasedMaterial
        let accent: PhysicallyBasedMaterial
    }

    /// Made on first use, with and without the lacquer; the wood texture is
    /// uploaded to the GPU once and shared by both.
    private static var looks: [Bool: (white: PieceLook, black: PieceLook)] = [:]
    private static var wood: MaterialParameters.Texture??

    private static func look(for color: PieceColor, clearCoat: Bool) -> PieceLook {
        let looks = self.looks[clearCoat] ?? makeLooks(clearCoat: clearCoat)
        self.looks[clearCoat] = looks
        return switch color {
        case .white: looks.white
        case .black: looks.black
        }
    }

    private static func makeLooks(clearCoat: Bool) -> (white: PieceLook, black: PieceLook) {
        let wood: MaterialParameters.Texture?
        if let cached = self.wood {
            wood = cached
        } else {
            wood = Signposts.poi.withIntervalSignpost("Wood texture") { makeWood() }
            self.wood = .some(wood)
        }
        func material(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, grain: Bool, gloss: Bool) -> PhysicallyBasedMaterial {
            var m = PhysicallyBasedMaterial()
            m.baseColor = .init(tint: .init(red: r, green: g, blue: b, alpha: 1), texture: grain ? wood : nil)
            m.roughness = .init(floatLiteral: gloss ? 0.32 : 0.8)
            m.metallic = 0.0
            m.clearcoat = .init(floatLiteral: gloss && clearCoat ? 0.7 : 0)
            m.clearcoatRoughness = 0.08
            return m
        }
        return (
            white: PieceLook(
                body: material(0.95, 0.88, 0.74, grain: true, gloss: true),
                accent: material(0.16, 0.1, 0.07, grain: false, gloss: false)),
            black: PieceLook(
                body: material(0.16, 0.11, 0.08, grain: true, gloss: true),
                accent: material(0.42, 0.33, 0.25, grain: false, gloss: false))
        )
    }

    private static func makePiece(_ piece: Piece, segments: Int, clearCoat: Bool) -> Entity {
        let mesh = mesh(for: piece.kind, segments: segments)
        let look = look(for: piece.color, clearCoat: clearCoat)
        let entity = ModelEntity(mesh: mesh.body, materials: [look.body])
        if let accent = mesh.accent {
            entity.addChild(ModelEntity(mesh: accent, materials: [look.accent]))
        }
        // Models face -z, towards Black; Black's pieces turn round to face White.
        if piece.color == .black {
            entity.orientation = simd_quatf(angle: .pi, axis: [0, 1, 0])
        }
        // One collision box per piece, so a tap anywhere on it counts.
        entity.components.set(InputTargetComponent())
        entity.components.set(
            CollisionComponent(shapes: [
                ShapeResource.generateBox(width: 2 * mesh.radius, height: mesh.height, depth: 2 * mesh.radius)
                    .offsetBy(translation: [0, mesh.height / 2, 0])
            ]))
        return entity
    }

    // MARK: - Squares and markers

    private func showSquares(_ state: State) {
        let check = state.position.isInCheck ? state.position.kingSquare(of: state.position.sideToMove) : nil
        for square in Square.all {
            let look: Look =
                switch square {
                case check: .check
                case hovered: .hovered
                case state.selected: .selected
                case state.lastMove?.from, state.lastMove?.to: .lastMove
                default: .plain
                }
            guard squareLooks[square] != look else { continue }
            squareLooks[square] = look
            squares[square]?.model?.materials = [Self.squareMaterial(square, look)]
        }
    }

    private func showTargets(_ targets: Set<Square>, on position: Position) {
        markers.children.removeAll()
        var material = UnlitMaterial(color: .black)
        material.blending = .transparent(opacity: 0.3)
        for square in targets {
            // A dot on an empty square, a wide disc under a capture.
            let mesh: MeshResource =
                position[square] == nil
                ? .generateCylinder(height: 0.02, radius: 0.14)
                : .generateCylinder(height: 0.02, radius: 0.46)
            let marker = ModelEntity(mesh: mesh, materials: [material])
            marker.position = Self.center(of: square) + [0, 0.011, 0]
            markers.addChild(marker)
        }
    }

    private static func squareMaterial(_ square: Square, _ look: Look) -> SimpleMaterial {
        let isLight = (square.file + square.rank) % 2 == 1
        let color: SimpleMaterial.Color =
            switch look {
            case .plain: (isLight ? BoardPalette.lightSquare : BoardPalette.darkSquare).materialColor
            case .lastMove:
                isLight
                    ? .init(red: 0.95, green: 0.86, blue: 0.48, alpha: 1)
                    : .init(red: 0.82, green: 0.66, blue: 0.30, alpha: 1)
            case .selected: .init(red: 0.55, green: 0.78, blue: 0.45, alpha: 1)
            case .hovered: .init(red: 0.6, green: 0.78, blue: 0.95, alpha: 1)
            case .check: .init(red: 0.86, green: 0.30, blue: 0.27, alpha: 1)
            }
        return SimpleMaterial(color: color, roughness: 0.8, isMetallic: false)
    }

    /// Top center of a square.
    private static func center(of square: Square) -> SIMD3<Float> {
        [Float(square.file) - 3.5, 0, 3.5 - Float(square.rank)]
    }
}

extension Comparable {
    fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
