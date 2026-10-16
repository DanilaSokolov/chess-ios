import ChessCore
import Foundation
import Testing

@testable import ChessClient

private func russian(_ key: String, _ args: any CVarArg...) throws -> String {
    let path = try #require(Bundle.module.path(forResource: "ru", ofType: "lproj"))
    let format = try #require(Bundle(path: path)).localizedString(forKey: key, value: nil, table: nil)
    return String(format: format, arguments: args)
}

@Test func squaresAreReadWithTheirPiece() {
    let e2 = Square("e2")!
    #expect(BoardDescription.square(e2, piece: Piece(.white, .pawn)) == "e2, white pawn")
    #expect(BoardDescription.square(Square("e4")!, piece: nil) == "e4, empty")
}

@Test func stateListsOnlyWhatApplies() {
    #expect(BoardDescription.state(isSelected: false, isTarget: false, isCapture: false, isLastMove: false) == nil)
    #expect(
        BoardDescription.state(isSelected: true, isTarget: false, isCapture: false, isLastMove: true)
            == "selected, last move")
    #expect(BoardDescription.state(isSelected: false, isTarget: true, isCapture: true, isLastMove: false) == "capture")
}

@Test func opponentMoveIsAnnounced() {
    let move = Move(uci: "g8f6")!
    #expect(
        BoardDescription.opponentMove(move, piece: Piece(.black, .knight), givesCheck: false)
            == "Opponent: black knight from g8 to f6")
    #expect(
        BoardDescription.opponentMove(move, piece: Piece(.black, .knight), givesCheck: true)
            == "Opponent: black knight from g8 to f6. Check!")
}

/// In Russian the colour agrees with the piece: «белая ладья», but «белый конь».
@Test func russianAgreesInGender() throws {
    #expect(try russian("white rook") == "белая ладья")
    #expect(try russian("white knight") == "белый конь")
    #expect(try russian("black queen") == "чёрный ферзь")
    #expect(try russian("Opponent: %@ from %@ to %@", "чёрный конь", "g8", "f6") == "Соперник: чёрный конь с g8 на f6")
    #expect(try russian("%@, empty", "e4") == "e4, пусто")
}
