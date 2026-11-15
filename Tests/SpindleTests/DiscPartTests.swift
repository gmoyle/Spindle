import XCTest
@testable import Spindle

/// A film on more than one disc, and bonus discs: "Which film is this?" can
/// say which disc a rip is, and the files are filed the way Plex groups them.
final class DiscPartTests: XCTestCase {

    private var root: String!
    private var movies: String!
    private var history: RipHistoryStore!
    private var pending: PendingRoutingQueue!
    private var suite: String!
    private let fm = FileManager.default
    private let mary = "There's Something About Mary (1998) {tmdb-544}"

    override func setUp() {
        super.setUp()
        root = NSTemporaryDirectory() + "DiscPartTests-\(UUID().uuidString)"
        movies = root + "/Movies"
        try? fm.createDirectory(atPath: movies, withIntermediateDirectories: true)
        history = RipHistoryStore(fileURL: URL(fileURLWithPath: root).appendingPathComponent("history.json"))
        suite = "DiscPartTests-\(UUID().uuidString)"
        pending = PendingRoutingQueue(defaults: UserDefaults(suiteName: suite)!)
    }

    override func tearDown() {
        try? fm.removeItem(atPath: root)
        UserDefaults().removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func write(_ folder: String, _ names: [String]) {
        try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for name in names { fm.createFile(atPath: folder + "/" + name, contents: Data(name.utf8)) }
    }

    private func sidecar(_ folder: String, _ name: String, volume: String) {
        let json = try? JSONSerialization.data(withJSONObject: ["source_path": "/Volumes/\(volume)",
                                                                "movie_name": "DVD_2026-11-14_07-59"])
        fm.createFile(atPath: folder + "/" + name, contents: json)
    }

    private func contents(_ folder: String) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    private func refile(_ folder: String, volume: String, from: String, to: String,
                        part: DiscPart?) throws -> String {
        try TitleRetitler.refile(folder: folder, volume: volume, from: from, to: to, part: part,
                                 history: history, pending: pending)
    }

    /// The case that went wrong: a bonus disc named as the film was filed
    /// beside it as "Version 2". Marked a bonus disc, its videos become extras.
    func testABonusDiscFiledAsAnEditionBecomesTheFilmsExtras() throws {
        let folder = movies + "/" + mary
        write(folder, ["\(mary).mkv", "\(mary).nfo",
                       "\(mary) {edition-Version 2}.mkv", "\(mary) {edition-Version 2}.nfo",
                       "\(mary) {edition-Version 2} - Bonus_Feature_04_00-11-42.mkv"])
        sidecar(folder, "disc_info.json", volume: "THERES_SOMETHING_ABOUT_MARY_4X3")
        sidecar(folder, "disc_info {edition-Version 2}.json", volume: "SOMETHING_ABOUT_MARY_DISC3")

        let result = try refile(folder, volume: "SOMETHING_ABOUT_MARY_DISC3", from: mary, to: mary, part: .bonus)

        XCTAssertEqual(result, folder)
        XCTAssertTrue(fm.fileExists(atPath: "\(folder)/\(mary).mkv"), "the film stays as it is")
        XCTAssertEqual(contents(folder + "/Featurettes"), ["Bonus Disc.mkv", "Bonus_Feature_04_00-11-42.mkv"])
        XCTAssertFalse(contents(folder).contains { $0.contains("{edition-") && !$0.hasPrefix("disc_info") },
                       "no second version of the film is left: \(contents(folder))")
        XCTAssertEqual(contents(folder).filter { $0.hasSuffix(".nfo") }, ["\(mary).nfo"])
        XCTAssertEqual(contents(folder).filter { $0.hasPrefix("disc_info") }.count, 2, "both discs stay recorded")
    }

    /// Disc 2 of a film, found confidently and filed beside disc 1 as an
    /// edition: as Disc 2 the two become part1 and part2 of one film.
    func testSecondDiscFiledAsAnEditionBecomesPartTwo() throws {
        let base = "Titanic (1997) {tmdb-597}"
        let folder = movies + "/" + base
        write(folder, ["\(base).mkv", "\(base) {edition-Version 2}.mkv", "\(base).nfo"])
        sidecar(folder, "disc_info.json", volume: "TITANIC_D1")
        sidecar(folder, "disc_info {edition-Version 2}.json", volume: "TITANIC_D2")

        try refile(folder, volume: "TITANIC_D2", from: base, to: base, part: .part(2))

        XCTAssertEqual(contents(folder).filter { $0.hasSuffix(".mkv") },
                       ["\(base) - part1.mkv", "\(base) - part2.mkv"])
    }

    /// A rip in its own folder named as disc 2 of a film already in the
    /// library joins its folder, and the film there becomes part 1.
    func testARipNamedAsDiscTwoJoinsTheFilm() throws {
        let base = "Lawrence of Arabia (1962) {tmdb-947}"
        write(movies + "/" + base, ["\(base).mkv", "\(base).nfo"])
        let rip = movies + "/DVD_VIDEO"
        write(rip, ["DVD_VIDEO.mkv", "DVD_VIDEO.nfo"])
        sidecar(rip, "disc_info.json", volume: "DVD_VIDEO")

        let result = try refile(rip, volume: "DVD_VIDEO", from: "DVD_VIDEO", to: base, part: .part(2))

        XCTAssertEqual(result, movies + "/" + base)
        XCTAssertFalse(fm.fileExists(atPath: rip))
        XCTAssertEqual(contents(result).filter { $0.hasSuffix(".mkv") || $0.hasSuffix(".nfo") },
                       ["\(base) - part1.mkv", "\(base) - part2.mkv", "\(base).nfo"])
    }

    /// Disc 1 ripped first, on its own: it's renamed part1, ready for disc 2.
    func testDiscOneAloneIsNamedPartOne() throws {
        let base = "Gone with the Wind (1939) {tmdb-770}"
        write(movies + "/" + base, ["\(base).mkv", "\(base) - Trailer.mkv"])

        let result = try refile(movies + "/" + base, volume: "GWTW_1", from: base, to: base, part: .part(1))

        XCTAssertEqual(contents(result), ["\(base) - Trailer.mkv", "\(base) - part1.mkv"])
    }

    func testPartNumbersAreReadFromFileNames() {
        XCTAssertEqual(DiscPart.partNumber(ofFile: "Heat (1995) - part2.mkv", base: "Heat (1995)"), 2)
        XCTAssertNil(DiscPart.partNumber(ofFile: "Heat (1995) - Trailer.mkv", base: "Heat (1995)"))
        XCTAssertEqual(MainViewController.ripDisplayName("Heat (1995) {tmdb-949}", part: .part(2)),
                       "Heat (1995) · Disc 2")
    }
}
