import XCTest
@testable import Spindle

/// Discs whose label doesn't name the film (a catalog number), and naming a
/// rip from Review Rips.
final class NamingUnnamedRipsTests: XCTestCase {

    func testCatalogNumbersArentTitles() {
        for label in ["23604", "0_43396_12345", "883929-04321"] {
            XCTAssertTrue(DiscTitleQuery.isGenericLabel(label), label)
        }
        for label in ["1917", "300", "2001", "21", "9", "2012_DISC"] {
            XCTAssertFalse(DiscTitleQuery.isGenericLabel(label), label)
        }
    }

    // MARK: - Naming a rip

    private var root: String!
    private var history: RipHistoryStore!
    private var pending: PendingRoutingQueue!
    private var suite: String!
    private let fm = FileManager.default

    override func setUp() {
        super.setUp()
        root = (NSTemporaryDirectory() as NSString).appendingPathComponent("naming-\(UUID().uuidString)")
        try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        history = RipHistoryStore(fileURL: URL(fileURLWithPath: root).appendingPathComponent("history.json"))
        suite = "naming-\(UUID().uuidString)"
        pending = PendingRoutingQueue(defaults: UserDefaults(suiteName: suite)!)
    }

    override func tearDown() {
        try? fm.removeItem(atPath: root)
        UserDefaults().removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func write(_ folder: String, _ name: String, bytes: Int) {
        fm.createFile(atPath: (folder as NSString).appendingPathComponent(name), contents: Data(count: bytes))
    }

    private func names(_ folder: String) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).filter { $0 != ".DS_Store" }.sorted()
    }

    func testNamingAnUnnamedRip() throws {
        let folder = (root as NSString).appendingPathComponent("23604")
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        write(folder, "Main_Movie_01-32-06.mkv", bytes: 5000)
        write(folder, "Trailer.mkv", bytes: 100)
        write(folder, "disc_info.json", bytes: 10)
        pending.enqueue(PendingRouting(discName: "23604", folderPath: folder, guessedType: .movie, confidence: 0.6))

        let renamed = try TitleRetitler.nameRip(folder: folder, to: "Heat (1995) {imdb-tt0113277}",
                                                history: history, pending: pending)

        XCTAssertEqual((renamed as NSString).lastPathComponent, "Heat (1995) {imdb-tt0113277}")
        XCTAssertFalse(fm.fileExists(atPath: folder))
        XCTAssertEqual(names(renamed), ["Heat (1995) {imdb-tt0113277} - Trailer.mkv",
                                        "Heat (1995) {imdb-tt0113277}.mkv",
                                        "Heat (1995) {imdb-tt0113277}.nfo",
                                        "disc_info.json"])
        let nfo = try String(contentsOfFile: renamed + "/Heat (1995) {imdb-tt0113277}.nfo")
        XCTAssertTrue(nfo.contains("tt0113277"))
        XCTAssertEqual(pending.items.first?.folderPath, renamed, "Review Rips follows the folder")
    }

    func testNamingARipAlreadyNamedAfterItsFolder() throws {
        let folder = (root as NSString).appendingPathComponent("Untitled Disc 2026-11-10 17-00")
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        write(folder, "Untitled Disc 2026-11-10 17-00.mkv", bytes: 5000)

        let renamed = try TitleRetitler.nameRip(folder: folder, to: "Heat (1995)", history: history, pending: pending)

        XCTAssertEqual(names(renamed), ["Heat (1995).mkv", "Heat (1995).nfo"])
    }

    func testReviewListShowsTheRipAndItsDisc() {
        let named = PendingRouting(discName: "HEAT_DC", folderPath: "/x/Heat (1995)", guessedType: .movie,
                                   confidence: 0.6)
        XCTAssertEqual(RoutingReviewWindowController.ripName(named), "Heat (1995)  ·  disc HEAT_DC")
        let unnamed = PendingRouting(discName: "23604", folderPath: "/x/23604", guessedType: .movie, confidence: 0.6)
        XCTAssertEqual(RoutingReviewWindowController.ripName(unnamed), "23604")
    }
}
