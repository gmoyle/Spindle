import XCTest
@testable import Spindle

/// Labels can't hold apostrophes and often carry the year: "OCEANS_ELEVEN_2001"
/// must still find "Ocean's Eleven (2001)", not the 1960 original.
final class DiscTitleQueryTests: XCTestCase {

    func testSpellingVariants() {
        XCTAssertEqual(DiscTitleQuery.candidates(fromVolumeName: "Oceans Eleven 2001"),
                       ["Oceans Eleven", "Ocean's Eleven", "Oceans Eleven 2001"])
        XCTAssertEqual(DiscTitleQuery.candidates(fromVolumeName: "SCHINDLERS_LIST"),
                       ["SCHINDLERS LIST", "SCHINDLER'S LIST"])
        XCTAssertEqual(DiscTitleQuery.candidates(fromVolumeName: "MATRIX_THE"),
                       ["MATRIX THE", "THE MATRIX"])
        // A final plural, a double s or an -us word gets no variant.
        XCTAssertEqual(DiscTitleQuery.candidates(fromVolumeName: "THE_GOONIES"), ["THE GOONIES"])
        XCTAssertEqual(DiscTitleQuery.candidates(fromVolumeName: "GLASS_ONION"), ["GLASS ONION"])
        XCTAssertEqual(DiscTitleQuery.candidates(fromVolumeName: "CORPUS_CHRISTI"), ["CORPUS CHRISTI"])
    }

    func testYearFromLabel() {
        XCTAssertEqual(DiscTitleQuery.year(inVolumeName: "OCEANS_ELEVEN_2001"), "2001")
        // Too far in the future to be a release year: part of the title.
        XCTAssertNil(DiscTitleQuery.year(inVolumeName: "BLADE_RUNNER_2049"))
        XCTAssertNil(DiscTitleQuery.year(inVolumeName: "APOLLO_13"))
        XCTAssertNil(DiscTitleQuery.year(inVolumeName: "THREE_KINGS"))
    }

    func testMatchingIgnoresPunctuationAndPrefersTheYear() {
        let matches = [MovieMatch(title: "The Making of 'Ocean's Eleven'", year: "2001"),
                       MovieMatch(title: "Ocean's Eleven", year: "1960"),
                       MovieMatch(title: "Ocean's Eleven", year: "2001")]
        XCTAssertEqual(DiscTitleQuery.bestMatch(for: "OCEANS ELEVEN", in: matches, year: "2001")?.displayName,
                       "Ocean's Eleven (2001)")
        XCTAssertEqual(DiscTitleQuery.bestMatch(for: "Ocean's Eleven", in: matches)?.displayName,
                       "Ocean's Eleven (1960)")
        XCTAssertEqual(DiscTitleQuery.normalized("Fast & Furious"), "fast and furious")
        XCTAssertEqual(DiscTitleQuery.normalized("Ocean\u{2019}s Eleven"), "oceans eleven")
    }
}

/// When a lookup isn't sure, the user is asked; their pick renames the rip.
final class TitleChoiceTests: TempFolderTestCase {

    private let eleven2001 = MovieMatch(title: "Ocean's Eleven", year: "2001")
    private let eleven1960 = MovieMatch(title: "Ocean's Eleven", year: "1960")
    private let makingOf = MovieMatch(title: "The Making of 'Ocean's Eleven'", year: "2001")

    func testConfidence() throws {
        // The label's year picks one film: sure.
        let sure = try XCTUnwrap(DiscTitleQuery.resolve(query: "OCEANS ELEVEN",
                                                        matches: [makingOf, eleven1960, eleven2001], year: "2001"))
        XCTAssertTrue(sure.isConfident)
        XCTAssertEqual(sure.best, eleven2001)
        XCTAssertEqual(sure.choices.first, eleven2001)
        XCTAssertEqual(sure.choices.count, 3)

        // Two films of that name and no year on the label: ask.
        let twoFilms = try XCTUnwrap(DiscTitleQuery.resolve(query: "OCEANS ELEVEN", matches: [eleven2001, eleven1960]))
        XCTAssertFalse(twoFilms.isConfident)

        // Nothing has the label's title: ask.
        let noExact = try XCTUnwrap(DiscTitleQuery.resolve(query: "OCEANS", matches: [eleven2001]))
        XCTAssertFalse(noExact.isConfident)

        // One film of that name, no year: sure.
        XCTAssertTrue(try XCTUnwrap(DiscTitleQuery.resolve(query: "Three Kings",
                                                           matches: [MovieMatch(title: "Three Kings", year: "1999")]))
            .isConfident)
        XCTAssertNil(DiscTitleQuery.resolve(query: "x", matches: []))
    }

    func testDiscOwnName() {
        XCTAssertEqual(MainViewController.discOwnName("Oceans Eleven 2001"), "Oceans Eleven (2001)")
        XCTAssertEqual(MainViewController.discOwnName("Hangmen"), "Hangmen")
    }

    func testRetitleRenamesFolderAndFiles() throws {
        let history = RipHistoryStore(fileURL: URL(fileURLWithPath: path("history.json")))
        let folder = path("Movies/Ocean's Eleven (1960)")
        try write("Movies/Ocean's Eleven (1960)/Ocean's Eleven (1960).mkv", "film")
        try write("Movies/Ocean's Eleven (1960)/Ocean's Eleven (1960) - Making Of.mkv", "extra")
        try write("Movies/Ocean's Eleven (1960)/rip_complete.json", "{}")
        history.record(RipHistoryEntry(discIdentity: "OCEANS#1", volumeName: "OCEANS", title: "x",
                                       settingsFingerprint: [:], outputLocation: folder, completedAt: Date()))

        let renamed = try TitleRetitler.retitle(folder: folder, from: "Ocean's Eleven (1960)",
                                                to: "Ocean's Eleven (2001)", history: history)
        XCTAssertEqual(renamed, path("Movies/Ocean's Eleven (2001)"))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: renamed).sorted(),
                       ["Ocean's Eleven (2001) - Making Of.mkv", "Ocean's Eleven (2001).mkv", "rip_complete.json"])
        XCTAssertFalse(fm.fileExists(atPath: folder))
        XCTAssertEqual(history.entry(forIdentity: "OCEANS#1")?.outputLocation, renamed)
    }

    func testRetitleKeepsAnotherFilmsFolder() throws {
        try write("Movies/Heat (1986)/Heat (1986).mkv", "guess")
        try write("Movies/Heat (1995)/Heat (1995).mkv", "already there")
        let renamed = try TitleRetitler.retitle(folder: path("Movies/Heat (1986)"), from: "Heat (1986)",
                                                to: "Heat (1995)",
                                                history: RipHistoryStore(fileURL: URL(fileURLWithPath: path("h.json"))))
        XCTAssertEqual(renamed, path("Movies/Heat (1995) (2)"))
        XCTAssertEqual(try String(contentsOfFile: path("Movies/Heat (1995)/Heat (1995).mkv")), "already there")
    }

    func testTitlesWithColonsAndTVRips() throws {
        XCTAssertEqual(TitleRetitler.fileBase("Mission: Impossible (1996)"), "Mission- Impossible (1996)")
        let files = ["/M/Mission- Impossible (1996)/Mission- Impossible (1996).mkv"]
        XCTAssertEqual(TitleRetitler.movieFolder(of: files, namedAfter: "Mission: Impossible (1996)"),
                       "/M/Mission- Impossible (1996)")
        // Episodes filed into a season folder aren't a movie folder.
        XCTAssertNil(TitleRetitler.movieFolder(of: ["/TV/Show/Season 01/a.mkv", "/TV/Show/Featurettes/b.mkv"],
                                               namedAfter: "Show (2002)"))
        XCTAssertThrowsError(try TitleRetitler.retitle(folder: path("Other"), from: "Heat (1995)", to: "Heat (1986)"))
    }
}
