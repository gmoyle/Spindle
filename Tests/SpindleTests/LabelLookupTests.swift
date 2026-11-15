import XCTest
@testable import Spindle

/// Disc labels that used to find nothing, or the wrong film, taken from real rips.
final class LabelLookupTests: XCTestCase {

    private func first(_ label: String) -> String? {
        DiscTitleQuery.candidates(fromVolumeName: label).first
    }

    func testPackagingWordsAreDropped() {
        XCTAssertEqual(first("ERASER_16X9_NA"), "ERASER")
        XCTAssertEqual(first("I_ROBOT_16X9"), "I ROBOT")
        XCTAssertEqual(first("LONG_KISS_GOODNIGHT_16X9LB"), "LONG KISS GOODNIGHT")
        XCTAssertEqual(first("THE_MATRIX_16X9LB_N_AMERICA"), "THE MATRIX")
        XCTAssertEqual(first("AMERICAN_WEDDING_UNRATED_16X9"), "AMERICAN WEDDING")
        XCTAssertEqual(first("SPACEBALLS_LB"), "SPACEBALLS")
    }

    func testSequelNumbersAreKept() {
        XCTAssertEqual(first("AMERICAN_PIE2_UNRATED_WIDE"), "AMERICAN PIE 2")
        XCTAssertEqual(first("AMERICAN_PIE_2"), "AMERICAN PIE 2")
        XCTAssertEqual(DiscTitleQuery.titleWords(fromVolumeName: "MI3_DOMESTIC_D1_WS"), ["MI", "3"])
        // Not a sequel: a "1", a year, a disc number.
        XCTAssertEqual(first("DIEHARD1"), "DIEHARD")
        XCTAssertEqual(first("OCEANS_ELEVEN_2001"), "OCEANS ELEVEN")
        XCTAssertEqual(first("SHREK_DISC_2"), "SHREK")
        XCTAssertEqual(first("ABYSS_D2"), "ABYSS")
    }

    func testRegionIsOnlyDroppedFromTheEnd() {
        XCTAssertEqual(first("NA"), "NA", "a label that's only the word stays")
        XCTAssertEqual(first("CAPTAIN_AMERICA"), "CAPTAIN AMERICA")
    }

    func testCutShortLabelAlsoSearchesWithoutItsLastWord() {
        let candidates = DiscTitleQuery.candidates(fromVolumeName: "BILL_AND_TEDS_EXCELLENT_ADVEN")
        XCTAssertTrue(candidates.contains("BILL AND TEDS EXCELLENT"), "\(candidates)")
        XCTAssertTrue(candidates.contains("BILL AND TED'S EXCELLENT"), "\(candidates)")
        XCTAssertFalse(DiscTitleQuery.candidates(fromVolumeName: "THE_BIG_LEBOWSKI").contains("THE BIG"))
    }

    func testLabelsThatDontNameTheFilm() {
        for label in ["SONY", "UNDEFINED", "Undefined", "WARNER_BROS", "NO_NAME"] {
            XCTAssertTrue(DiscTitleQuery.isGenericLabel(label), label)
        }
        for label in ["SONY_PICTURES_CLASSICS_PRESENTS_X", "UNIVERSAL_SOLDIER"] {
            XCTAssertFalse(DiscTitleQuery.isGenericLabel(label), label)
        }
    }

    func testALeadingTheDoesntStopAnExactMatch() {
        let matches = [MovieMatch(title: "The Long Kiss Goodnight", year: "1996", posterURL: nil, imdbID: "tt0116908")]
        let resolution = DiscTitleQuery.resolve(query: "LONG KISS GOODNIGHT", matches: matches)
        XCTAssertEqual(resolution?.isConfident, true)
        XCTAssertEqual(DiscTitleQuery.normalized("The"), "the", "a film called just The keeps it")
    }

    func testSequelsAreAlsoSearchedWithRomanNumerals() {
        XCTAssertEqual(Array(DiscTitleQuery.candidates(fromVolumeName: "MI3_DOMESTIC_D1_WS").prefix(4)),
                       ["MISSION IMPOSSIBLE 3", "MISSION IMPOSSIBLE III", "MI 3", "MI III"])
        XCTAssertEqual(Array(DiscTitleQuery.candidates(fromVolumeName: "AMERICAN_PIE2_UNRATED_WIDE").prefix(2)),
                       ["AMERICAN PIE 2", "AMERICAN PIE II"])
    }

    /// Answers each query from a table; records what was searched.
    private final class TableMovies: MovieMetadataProvider {
        let name = "Table"
        let table: [String: [MovieMatch]]
        var searched: [String] = []
        init(_ table: [String: [MovieMatch]]) { self.table = table }
        func searchMovies(query: String, completion: @escaping ([MovieMatch]) -> Void) {
            searched.append(query)
            completion(table[query] ?? [])
        }
    }

    private func lookUp(_ label: String, in provider: TableMovies) -> DiscTitleQuery.Resolution? {
        var answer: DiscTitleQuery.Resolution?
        DiscTitleQuery.lookUp(candidates: DiscTitleQuery.candidates(fromVolumeName: label),
                              year: DiscTitleQuery.year(inVolumeName: label), provider: provider) { answer = $0 }
        return answer
    }

    func testLookupKeepsGoingPastAnUnsureMatch() {
        let wrong = MovieMatch(title: "Mi verano con Amanda 3", year: "2013")
        let right = MovieMatch(title: "Mission: Impossible III", year: "2006", posterURL: nil, imdbID: "tt0317919")
        let provider = TableMovies(["MI 3": [wrong], "MISSION IMPOSSIBLE III": [right]])
        let answer = lookUp("MI3_DOMESTIC_D1_WS", in: provider)
        XCTAssertEqual(answer?.best, right)
        XCTAssertEqual(answer?.isConfident, true)
    }

    func testLookupFallsBackToTheFirstUnsureMatch() {
        let first = MovieMatch(title: "DieHard is Back", year: "2020")
        let provider = TableMovies(["DIEHARD": [first]])
        let answer = lookUp("DIEHARD1", in: provider)
        XCTAssertEqual(answer?.best, first)
        XCTAssertEqual(answer?.isConfident, false)
        XCTAssertNil(lookUp("FIGHTCLB", in: TableMovies([:])))
    }

    func testUnfoundDiscRipsUnderItsLabelAsAFilmName() {
        XCTAssertEqual(MainViewController.unfoundRipName(forLabel: "I_ROBOT_16X9"), "I ROBOT")
        XCTAssertEqual(MainViewController.unfoundRipName(forLabel: "FIGHTCLB"), "FIGHTCLB")
        XCTAssertNil(MainViewController.unfoundRipName(forLabel: "FIREFLY_S1_D1"), "TV discs keep their label")
    }
}
