import XCTest
@testable import Spindle

/// Home videos on pressed discs: spotting them, and filing a rip as one.
final class HomeVideoChoiceTests: XCTestCase {

    // MARK: - Spotting a home-made disc

    private func ifoHeader(region: UInt8) -> Data {
        var bytes = [UInt8](repeating: 0, count: 0x40)
        bytes.replaceSubrange(0..<12, with: Array("DVDVIDEO-VMG".utf8))
        bytes[0x23] = region
        return Data(bytes)
    }

    func testRegionMaskFromTheIFO() {
        XCTAssertEqual(HomeMadeDiscCheck.regionMask(ifoHeader: ifoHeader(region: 0x00)), 0x00)
        XCTAssertEqual(HomeMadeDiscCheck.regionMask(ifoHeader: ifoHeader(region: 0xFE)), 0xFE, "region 1 only")
        XCTAssertNil(HomeMadeDiscCheck.regionMask(ifoHeader: Data(repeating: 0, count: 0x40)), "not an IFO")
        XCTAssertNil(HomeMadeDiscCheck.regionMask(ifoHeader: Data("DVDVIDEO-VMG".utf8)), "too short")
    }

    func testOnlyUnprotectedRegionFreeDiscsLookHomeMade() {
        XCTAssertTrue(HomeMadeDiscCheck.Signs(scrambled: false, regionMask: 0).looksHomeMade)
        XCTAssertFalse(HomeMadeDiscCheck.Signs(scrambled: true, regionMask: 0).looksHomeMade)
        XCTAssertFalse(HomeMadeDiscCheck.Signs(scrambled: false, regionMask: 0xFE).looksHomeMade)
        XCTAssertFalse(HomeMadeDiscCheck.Signs(scrambled: nil, regionMask: 0).looksHomeMade, "unknown isn't home-made")
        XCTAssertFalse(HomeMadeDiscCheck.Signs(scrambled: false, regionMask: nil).looksHomeMade)
    }

    // MARK: - Filing a rip as a home video

    private var root: String!
    private var history: RipHistoryStore!
    private var pending: PendingRoutingQueue!
    private var suite: String!
    private let fm = FileManager.default

    override func setUp() {
        super.setUp()
        root = (NSTemporaryDirectory() as NSString).appendingPathComponent("home-\(UUID().uuidString)")
        try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        history = RipHistoryStore(fileURL: URL(fileURLWithPath: root).appendingPathComponent("history.json"))
        suite = "home-\(UUID().uuidString)"
        pending = PendingRoutingQueue(defaults: UserDefaults(suiteName: suite)!)
    }

    override func tearDown() {
        try? fm.removeItem(atPath: root)
        UserDefaults().removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func path(_ parts: String...) -> String {
        parts.reduce(root) { ($0 as NSString).appendingPathComponent($1) }
    }

    private func names(_ folder: String) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).filter { $0 != ".DS_Store" }.sorted()
    }

    private func makeRip(_ name: String, videos: [String], discCreated: String?) throws -> String {
        let folder = path("Movies", name)
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for video in videos {
            fm.createFile(atPath: (folder as NSString).appendingPathComponent(video), contents: Data())
        }
        fm.createFile(atPath: (folder as NSString).appendingPathComponent("\(name).nfo"), contents: Data())
        var info: [String: Any] = ["movie_name": name]
        if let created = discCreated { info[HomeVideoFiler.discCreatedKey] = created }
        try JSONSerialization.data(withJSONObject: info)
            .write(to: URL(fileURLWithPath: (folder as NSString).appendingPathComponent("disc_info.json")))
        return folder
    }

    func testFilingARipAsAHomeVideo() throws {
        let folder = try makeRip("5THGRADE2016", videos: ["5THGRADE2016.mkv"], discCreated: "2016-11-30T21:39:55Z")
        pending.enqueue(PendingRouting(discName: "5THGRADE2016", folderPath: folder, guessedType: .movie,
                                       confidence: 0.6))
        let info = HomeVideoFiler.info(forRipIn: folder, label: "5THGRADE2016")
        let filed = try HomeVideoFiler.file(folder: folder, as: info, into: path("Home Videos"),
                                            history: history, pending: pending)

        let day = HomeVideoInfo.dayFormatter.string(from: info.date)
        XCTAssertTrue(day.hasPrefix("2016-11-"), day)
        XCTAssertEqual((filed as NSString).lastPathComponent, "\(day) 5thgrade2016")
        XCTAssertEqual(names(filed), ["\(day) 5thgrade2016.mkv", "disc_info.json"], "the film nfo is dropped")
        XCTAssertFalse(fm.fileExists(atPath: folder))
        XCTAssertEqual(pending.items.first?.folderPath, filed)
    }

    func testSeveralRecordingsAreNumberedInDiscOrder() throws {
        let folder = try makeRip("RECITAL", videos: ["title_t10.mkv", "title_t02.mkv", "title_t01.mkv"],
                                 discCreated: nil)
        let info = HomeVideoInfo(date: Date(timeIntervalSince1970: 1_400_000_000), label: "Recital")
        let filed = try HomeVideoFiler.file(folder: folder, as: info, into: path("Home Videos"),
                                            history: history, pending: pending)
        let base = info.folderName
        XCTAssertEqual(names(filed), ["\(base) - 01.mkv", "\(base) - 02.mkv", "\(base) - 03.mkv",
                                      "disc_info.json"])
    }

    func testDateFromTheLabelWins() throws {
        let folder = try makeRip("2004_07_14", videos: ["a.mkv"], discCreated: "2016-11-30T21:39:55Z")
        let info = HomeVideoFiler.info(forRipIn: folder, label: "2004_07_14")
        XCTAssertEqual(info.folderName, "2004-07-14 Home Video")
    }

    func testAnExistingFolderIsntOverwritten() throws {
        let info = HomeVideoInfo(date: Date(timeIntervalSince1970: 1_400_000_000), label: "Recital")
        try fm.createDirectory(atPath: path("Home Videos", info.folderName), withIntermediateDirectories: true)
        let folder = try makeRip("RECITAL", videos: ["a.mkv"], discCreated: nil)
        let filed = try HomeVideoFiler.file(folder: folder, as: info, into: path("Home Videos"),
                                            history: history, pending: pending)
        XCTAssertNotEqual(filed, path("Home Videos", info.folderName))
    }
}
