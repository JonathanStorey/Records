import Foundation
import Testing
@testable import Records

@Record
struct Gauge: Equatable {
    var id: UUID
    var name: String
    var level: Double
    var steps: Int
    var limit: Int
    var checkedAt: Date
    var isOn: Bool
    var mood: Mood
    var rating: Rating?
    var nickname: String?
}

private let start = Date(timeIntervalSinceReferenceDate: 800_000_000.123456)

private func gauge(
    _ name: String, level: Double = 1, steps: Int = 0, limit: Int = 5, checkedAt: Date = start,
    isOn: Bool = false, mood: Mood = .calm, rating: Rating? = nil, nickname: String? = nil
) -> Gauge {
    Gauge(
        id: UUID(), name: name, level: level, steps: steps, limit: limit, checkedAt: checkedAt,
        isOn: isOn, mood: mood, rating: rating, nickname: nickname
    )
}

private func translate(_ predicate: Predicate<Gauge>) -> (sql: String, values: [SQLValue], isExact: Bool)? {
    PredicateTranslator(for: Gauge.self).translate(predicate).map { ($0.filter.sql, $0.filter.values, $0.isExact) }
}

// Enum cases can't be written inside `#Predicate`, so predicates capture them.
private let energetic = Mood.energetic
private let two: Rating? = .two

// MARK: - Translation

@Test func equalityOnAnIntegerIsExact() throws {
    let result = try #require(translate(#Predicate { $0.steps == 3 }))
    #expect(result.sql == #"("steps" IS ?)"#)
    #expect(result.values == [.integer(3)])
    #expect(result.isExact)
}

@Test func orderedComparisonsOnNumbersAreExact() throws {
    let result = try #require(translate(#Predicate { $0.steps < 2 || $0.level >= 1.5 }))
    #expect(result.sql == #"(("steps" < ?) OR ("level" >= ?))"#)
    #expect(result.values == [.integer(2), .real(1.5)])
    #expect(result.isExact)
}

@Test func aConstantOnTheLeftSwapsTheComparison() throws {
    let result = try #require(translate(#Predicate { 3 < $0.steps }))
    #expect(result.sql == #"("steps" > ?)"#)
}

@Test func capturedValuesAreBound() throws {
    let limit = 4
    let result = try #require(translate(#Predicate { $0.steps != limit }))
    #expect(result.sql == #"("steps" IS NOT ?)"#)
    #expect(result.values == [.integer(4)])
}

@Test func aBooleanPropertyIsACondition() throws {
    let result = try #require(translate(#Predicate { $0.isOn }))
    #expect(result.sql == #"("isOn" IS 1)"#)
    #expect(result.isExact)
    let negated = try #require(translate(#Predicate { !$0.isOn }))
    #expect(negated.sql == #"(NOT COALESCE(("isOn" IS 1), 0))"#)
}

@Test func nilIsComparedWithIs() throws {
    let result = try #require(translate(#Predicate { $0.rating == nil }))
    #expect(result.sql == #"("rating" IS NULL)"#)
    #expect(result.isExact)
    #expect(try #require(translate(#Predicate { $0.nickname != nil })).sql == #"("nickname" IS NOT NULL)"#)
}

@Test func enumsAreComparedByRawValue() throws {
    let rating = try #require(translate(#Predicate { $0.rating == two }))
    #expect(rating.values == [.integer(2)])
    #expect(rating.isExact)
    let mood = try #require(translate(#Predicate { $0.mood == energetic }))
    #expect(mood.values == [.text("energetic")])
}

@Test func theIDIsTheRecordName() throws {
    let id = UUID()
    let result = try #require(translate(#Predicate { $0.id == id }))
    #expect(result.sql == #"("_name" IS ?)"#)
    #expect(result.values == [.text(id.uuidString)])
    #expect(result.isExact)
}

@Test func stringEqualityLetsThroughTextBeyondASCII() throws {
    let result = try #require(translate(#Predicate { $0.name == "Hall" }))
    #expect(result.sql == #"("name" IS ? OR "name" GLOB '*[^ -~]*')"#)
    #expect(!result.isExact)
}

@Test func stringOrderIsLeftToSwift() {
    #expect(translate(#Predicate { $0.name < "b" }) == nil)
    #expect(translate(#Predicate { $0.name.contains("a") }) == nil)
}

@Test func datesUseLooseBounds() throws {
    let result = try #require(translate(#Predicate { $0.checkedAt > start }))
    #expect(result.sql == #"("checkedAt" >= ?)"#)
    #expect(result.values == [.real(start.timeIntervalSince1970)])
    #expect(!result.isExact)
    #expect(translate(#Predicate { $0.checkedAt != start }) == nil)
}

@Test func integerPropertiesCompareWithEachOther() throws {
    let result = try #require(translate(#Predicate { $0.steps < $0.limit }))
    #expect(result.sql == #"("steps" < "limit")"#)
    #expect(result.isExact)
}

@Test func anUntranslatablePartOfAConjunctionIsDropped() throws {
    let result = try #require(translate(#Predicate { $0.steps > 1 && $0.name.contains("a") }))
    #expect(result.sql == #"("steps" > ?)"#)
    #expect(!result.isExact)
    #expect(translate(#Predicate { $0.steps > 1 || $0.name.contains("a") }) == nil)
    #expect(translate(#Predicate { !($0.steps > 1 && $0.name.contains("a")) }) == nil)
}

@Test func containsBecomesAnyOfTheValues() throws {
    let result = try #require(translate(#Predicate { [1, 2].contains($0.steps) }))
    #expect(result.sql == #"(("steps" IS ?) OR ("steps" IS ?))"#)
    #expect(result.values == [.integer(1), .integer(2)])
    #expect(result.isExact)
    let none: [Int] = []
    #expect(try #require(translate(#Predicate { none.contains($0.steps) })).sql == "0")
}

// MARK: - Fetching

/// Records chosen to sit where SQL and Swift could disagree.
private let gauges = [
    gauge("Hall", level: 0.5, steps: 1, limit: 1, isOn: true, rating: .one),
    gauge("hall", level: 1.5, steps: 2, checkedAt: start.addingTimeInterval(1e-7), mood: .energetic),
    gauge("Cafe\u{301}", level: 2, steps: 3, checkedAt: start.addingTimeInterval(-1e-7), rating: .two, nickname: "C"),
    gauge("Café", level: -1, steps: 7, limit: 9, checkedAt: start.addingTimeInterval(60), isOn: true),
    gauge("\u{212A}iln", steps: 5, rating: .three, nickname: "Kiln"),
    gauge("Kiln", level: 3, steps: 10, limit: 2),
]

private let predicates: [Predicate<Gauge>] = [
    #Predicate { $0.steps == 3 },
    #Predicate { $0.steps != 3 },
    #Predicate { $0.steps >= 3 && $0.level < 2 },
    #Predicate { $0.steps < $0.limit },
    #Predicate { !($0.level > 1) },
    #Predicate { $0.isOn },
    #Predicate { !$0.isOn || $0.steps > 5 },
    #Predicate { $0.rating == nil },
    #Predicate { $0.rating != two },
    #Predicate { $0.nickname != nil },
    #Predicate { $0.mood == energetic },
    #Predicate { $0.name == "Café" },
    #Predicate { $0.name == "Kiln" },
    #Predicate { $0.name != "Kiln" },
    #Predicate { !($0.name == "Kiln") },
    #Predicate { $0.name == "hall" || $0.steps == 10 },
    #Predicate { ["Kiln", "Hall"].contains($0.name) },
    #Predicate { [1, 5].contains($0.steps) },
    #Predicate { $0.checkedAt == start },
    #Predicate { $0.checkedAt > start },
    #Predicate { $0.checkedAt <= start },
    #Predicate { !($0.checkedAt < start) },
    #Predicate { $0.name.contains("al") && $0.steps > 1 },
]

@MainActor
@Test func fetchingWithSQLMatchesEvaluatingInSwift() throws {
    let context = try RecordContainer(for: [Gauge.self], url: nil).mainContext
    for gauge in gauges { context.insert(gauge) }
    try context.save()
    let saved = try context.fetch(RecordDescriptor<Gauge>())
    #expect(saved.count == gauges.count)

    for (index, predicate) in predicates.enumerated() {
        let expected = Set(try saved.filter { try predicate.evaluate($0) }.map(\.id))
        let fetched = Set(try context.fetch(RecordDescriptor(predicate: predicate)).map(\.id))
        #expect(fetched == expected, "predicate \(index)")
    }
}

@MainActor
@Test func exactSQLAloneMatchesEvaluatingInSwift() throws {
    let container = try RecordContainer(for: [Gauge.self], url: nil)
    let context = container.mainContext
    for gauge in gauges { context.insert(gauge) }
    try context.save()
    let saved = try context.fetch(RecordDescriptor<Gauge>())
    let translator = PredicateTranslator(for: Gauge.self)

    for (index, predicate) in predicates.enumerated() {
        guard let result = translator.translate(predicate), result.isExact else { continue }
        let filter = result.filter
        let expected = Set(try saved.filter { try predicate.evaluate($0) }.map(\.id.uuidString))
        let rows = try context.database.rows(
            "SELECT \"_name\" FROM \"Gauge\" WHERE \"_isCurrent\" = 1 AND \(filter.sql)", filter.values
        )
        let matched = Set(rows.compactMap { row -> String? in
            if case .text(let name)? = row["_name"] { name } else { nil }
        })
        #expect(matched == expected, "predicate \(index)")
    }
}
