import Foundation
import Testing

@testable import ChessClient

/// The Russian translations of the package's strings, read from the compiled
/// catalog, as the app would see them with the device set to Russian.
private func russian() throws -> Bundle {
    let path = try #require(Bundle.module.path(forResource: "ru", ofType: "lproj"), "no ru.lproj in the bundle")
    return try #require(Bundle(path: path))
}

@Test func everyStringHasARussianTranslation() throws {
    let ru = try russian()
    let table = try #require(
        NSDictionary(contentsOf: ru.url(forResource: "Localizable", withExtension: "strings")!) as? [String: String])
    #expect(table.count >= 16)
    for (key, value) in table {
        #expect(value != key, "\(key) is not translated")
        // A translation must take the same arguments, or String(format:) misreads them.
        #expect(arguments(of: value) == arguments(of: key), "\(key) → \(value)")
    }
}

@Test func serverErrorIsShownInRussian() throws {
    let ru = try russian()
    #expect(ru.localizedString(forKey: "Leave your room first", value: nil, table: nil) == "Сначала выйдите из комнаты")
    let format = ru.localizedString(forKey: "Move rejected: %@", value: nil, table: nil)
    #expect(String(format: format, "illegal move") == "Ход отклонён: illegal move")
}

@Test func moveRejectionsAreTranslated() throws {
    let ru = try russian()
    #expect(ru.localizedString(forKey: "It is not your move", value: nil, table: nil) == "Сейчас не ваш ход")
    #expect(moveRejectionText("not your turn") == "It is not your move")
    #expect(
        ru.localizedString(forKey: "The server did not accept the move", value: nil, table: nil)
            == "Сервер не принял ход")
}

@Test func characterLimitAgreesWithTheNumber() throws {
    let ru = try russian()
    let format = ru.localizedString(forKey: "At most %lld characters", value: nil, table: nil)
    let say = { (n: Int) in String(format: format, locale: Locale(identifier: "ru"), n) }
    #expect(say(1) == "Не больше 1 символа")
    #expect(say(3) == "Не больше 3 символов")
    #expect(say(200) == "Не больше 200 символов")
    #expect(say(21) == "Не больше 21 символа")
}

/// The arguments a format string takes: position → type. "%1$@" and "%@"
/// both name an argument; positions let a translation reorder the words.
private func arguments(of format: String) -> [Int: String] {
    var result: [Int: String] = [:]
    var next = 1
    for match in format.matches(of: /%(?:(\d+)\$)?(lld|@)/) {
        let position = match.output.1.flatMap { Int($0) } ?? next
        result[position] = String(match.output.2)
        next = position + 1
    }
    return result
}

@Test func positionalArgumentsCountAsTheSame() {
    #expect(arguments(of: "Соперник: %1$@ с %2$@ на %3$@") == arguments(of: "Opponent: %@ from %@ to %@"))
    #expect(arguments(of: "%2$@ %1$lld") != arguments(of: "%@ %lld"), "a swapped type is still caught")
}
