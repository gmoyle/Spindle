import XCTest
@testable import Spindle

final class MovieEditionTests: XCTestCase {

    // MARK: - Labels

    func testEditionIsReadFromTheLabel() {
        let split = MovieEdition.split(volumeName: "ARMY_OF_DARKNESS_DIRECTORS_CUT")
        XCTAssertEqual(split.titleWords, ["ARMY", "OF", "DARKNESS"])
        XCTAssertEqual(split.edition, "Director's Cut")
        XCTAssertEqual(MovieEdition.edition(inVolumeName: "ARMY_OF_DARKNESS_THEATRICAL"), "Theatrical Cut")
        XCTAssertEqual(MovieEdition.edition(inVolumeName: "LOTR_FOTR_EXTENDED_EDITION"), "Extended Edition")
        XCTAssertEqual(MovieEdition.edition(inVolumeName: "APOCALYPSE_NOW_REDUX"), "Redux")
        XCTAssertEqual(MovieEdition.edition(inVolumeName: "BLADE_RUNNER_FINAL_CUT"), "Final Cut")
        XCTAssertEqual(MovieEdition.split(volumeName: "ARMY_OF_DARKNESS_DC").titleWords, ["ARMY", "OF", "DARKNESS"])
        XCTAssertEqual(MovieEdition.edition(inVolumeName: "ARMY_OF_DARKNESS_DC"), "Director's Cut")
        XCTAssertNil(MovieEdition.edition(inVolumeName: "DC_SUPERHEROES"), "only as the last word")
        XCTAssertNil(MovieEdition.edition(inVolumeName: "THE_DC"))
    }

    func testTitlesThatLookLikeEditionsStayTitles() {
        XCTAssertNil(MovieEdition.edition(inVolumeName: "THE_FINAL_CUT"))
        XCTAssertNil(MovieEdition.edition(inVolumeName: "UNRATED"))
        XCTAssertNil(MovieEdition.edition(inVolumeName: "ALIENS"))
    }

    func testLookupSearchesWithoutTheEdition() {
        XCTAssertEqual(DiscTitleQuery.candidates(fromVolumeName: "ARMY_OF_DARKNESS_DIRECTORS_CUT").first,
                       "ARMY OF DARKNESS")
    }

    func testFileNameTags() {
        XCTAssertEqual(MovieEdition.taggedBase("Army of Darkness (1993)", edition: "Director's Cut"),
                       "Army of Darkness (1993) {edition-Director's Cut}")
        XCTAssertEqual(MovieEdition.edition(inFileName: "Film (2000) {edition-Redux}.mkv"), "Redux")
        XCTAssertTrue(MovieEdition.isUntaggedFilmFile("Film (2000).mkv", base: "Film (2000)"))
        XCTAssertTrue(MovieEdition.isUntaggedFilmFile("Film (2000) - Extra.mkv", base: "Film (2000)"))
        XCTAssertFalse(MovieEdition.isUntaggedFilmFile("Film (2000) {edition-Redux}.mkv", base: "Film (2000)"))
        XCTAssertFalse(MovieEdition.isUntaggedFilmFile("poster.jpg", base: "Film (2000)"))
    }

    // MARK: - Filing

    private var root: String!
    private var library: String!
    private var history: RipHistoryStore!
    private let fm = FileManager.default
    private let base = "Army of Darkness (1993)"

    override func setUp() {
        super.setUp()
        root = (NSTemporaryDirectory() as NSString).appendingPathComponent("editions-\(UUID().uuidString)")
        library = (root as NSString).appendingPathComponent("Movies")
        try? fm.createDirectory(atPath: library, withIntermediateDirectories: true)
        history = RipHistoryStore(fileURL: URL(fileURLWithPath: root).appendingPathComponent("history.json"))
    }

    override func tearDown() {
        try? fm.removeItem(atPath: root)
        super.tearDown()
    }

    /// A rip folder named after the film, holding its file and sidecar.
    @discardableResult
    private func makeRip(in parent: String, label: String, content: String) -> String {
        let folder = (parent as NSString).appendingPathComponent(base)
        try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        fm.createFile(atPath: (folder as NSString).appendingPathComponent("\(base).mkv"),
                      contents: Data(content.utf8))
        let info = try? JSONSerialization.data(withJSONObject: ["movie_name": label])
        fm.createFile(atPath: (folder as NSString).appendingPathComponent("disc_info.json"), contents: info)
        return folder
    }

    private func staging(_ name: String) -> String {
        let path = (root as NSString).appendingPathComponent(name)
        try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func contents(_ folder: String) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).filter { $0 != ".DS_Store" }.sorted()
    }

    private func read(_ folder: String, _ name: String) -> String? {
        fm.contents(atPath: (folder as NSString).appendingPathComponent(name))
            .flatMap { String(bytes: $0, encoding: .utf8) }
    }

    private func file(_ source: String, identity: String = UUID().uuidString) throws -> String {
        try LibraryFiles.fileFolder(source, into: library, discIdentity: identity, asEditions: true, history: history)
    }

    func testDirectorsCutJoinsTheTheatricalCutsFolder() throws {
        makeRip(in: library, label: "ARMY_OF_DARKNESS_THEATRICAL", content: "theatrical")
        let source = makeRip(in: staging("dc"), label: "ARMY_OF_DARKNESS_DIRECTORS_CUT", content: "dc")

        let destination = try file(source)

        XCTAssertEqual((destination as NSString).lastPathComponent, base)
        XCTAssertEqual(contents(destination), [
            "\(base) {edition-Director's Cut}.mkv",
            "\(base) {edition-Theatrical Cut}.mkv",
            "disc_info {edition-Director's Cut}.json",
            "disc_info {edition-Theatrical Cut}.json"
        ])
        XCTAssertEqual(read(destination, "\(base) {edition-Theatrical Cut}.mkv"), "theatrical")
        XCTAssertEqual(read(destination, "\(base) {edition-Director's Cut}.mkv"), "dc")
        XCTAssertFalse(fm.fileExists(atPath: source))
        XCTAssertEqual(contents(library), [base], "no \"(2)\" folder")
    }

    func testAnUnnamedFirstRipStaysTheDefaultEdition() throws {
        makeRip(in: library, label: "ARMY_OF_DARKNESS", content: "first")
        let source = makeRip(in: staging("dc"), label: "ARMY_OF_DARKNESS_DIRECTORS_CUT", content: "dc")

        let destination = try file(source)

        XCTAssertEqual(read(destination, "\(base).mkv"), "first")
        XCTAssertEqual(read(destination, "\(base) {edition-Director's Cut}.mkv"), "dc")
    }

    func testAnUnnamedSecondDiscBecomesVersion2() throws {
        makeRip(in: library, label: "ARMY_OF_DARKNESS", content: "first")
        let source = makeRip(in: staging("other"), label: "AOD_DISC", content: "second")

        let destination = try file(source)

        XCTAssertEqual(read(destination, "\(base).mkv"), "first")
        XCTAssertEqual(read(destination, "\(base) {edition-Version 2}.mkv"), "second")
    }

    func testReRippingOneEditionReplacesOnlyThatEdition() throws {
        makeRip(in: library, label: "ARMY_OF_DARKNESS_THEATRICAL", content: "theatrical")
        let identity = "AOD_DC#1"
        let destination = try file(makeRip(in: staging("dc1"), label: "ARMY_OF_DARKNESS_DIRECTORS_CUT",
                                           content: "dc v1"), identity: identity)
        history.record(RipHistoryEntry(discIdentity: identity, volumeName: "ARMY_OF_DARKNESS_DIRECTORS_CUT",
                                       title: base, settingsFingerprint: [:], outputLocation: destination,
                                       completedAt: Date()))

        _ = try file(makeRip(in: staging("dc2"), label: "ARMY_OF_DARKNESS_DIRECTORS_CUT", content: "dc v2"),
                     identity: identity)

        XCTAssertEqual(read(destination, "\(base) {edition-Theatrical Cut}.mkv"), "theatrical")
        XCTAssertEqual(read(destination, "\(base) {edition-Director's Cut}.mkv"), "dc v2")
        XCTAssertEqual(contents(destination).filter { $0.hasSuffix(".mkv") }.count, 2)
    }

    func testSameEditionFromAnotherDiscGetsItsOwnName() throws {
        makeRip(in: library, label: "ARMY_OF_DARKNESS_DIRECTORS_CUT", content: "dc 1")
        let source = makeRip(in: staging("dc"), label: "AOD_DIRECTORS_CUT", content: "dc 2")

        let destination = try file(source)

        XCTAssertEqual(read(destination, "\(base) {edition-Director's Cut}.mkv"), "dc 1")
        XCTAssertEqual(read(destination, "\(base) {edition-Director's Cut 2}.mkv"), "dc 2")
    }

    func testFoldersThatArentFilmsStillGetASeparateFolder() throws {
        makeRip(in: library, label: "SHOW_S1_D1", content: "one")
        let source = makeRip(in: staging("tv"), label: "SHOW_S1_D2", content: "two")

        let destination = try LibraryFiles.fileFolder(source, into: library, discIdentity: "x", history: history)

        XCTAssertEqual((destination as NSString).lastPathComponent, "\(base) (2)")
    }
}

final class RetitleIntoEditionTests: XCTestCase {

    func testChoosingAFilmAlreadyInTheLibraryAddsAnEdition() throws {
        let fm = FileManager.default
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("retitle-\(UUID().uuidString)")
        defer { try? fm.removeItem(atPath: root) }
        let film = (root as NSString).appendingPathComponent("Army of Darkness (1993)")
        let guess = (root as NSString).appendingPathComponent("Army Of Darkness Dc")
        try fm.createDirectory(atPath: film, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: guess, withIntermediateDirectories: true)
        fm.createFile(atPath: film + "/Army of Darkness (1993).mkv", contents: Data("theatrical".utf8))
        let theatrical = ["movie_name": "ARMY_OF_DARKNESS_THEATRICAL"]
        fm.createFile(atPath: film + "/disc_info.json", contents: try JSONSerialization.data(withJSONObject: theatrical))
        fm.createFile(atPath: guess + "/Army Of Darkness Dc.mkv", contents: Data("dc".utf8))
        fm.createFile(atPath: guess + "/disc_info.json",
                      contents: try JSONSerialization.data(withJSONObject: ["movie_name": "ARMY_OF_DARKNESS_DC"]))
        let history = RipHistoryStore(fileURL: URL(fileURLWithPath: root).appendingPathComponent("h.json"))

        let result = try TitleRetitler.retitle(folder: guess, from: "Army Of Darkness Dc",
                                               to: "Army of Darkness (1993)", history: history)

        XCTAssertEqual(result, film)
        XCTAssertFalse(fm.fileExists(atPath: guess))
        XCTAssertTrue(fm.fileExists(atPath: film + "/Army of Darkness (1993) {edition-Director's Cut}.mkv"))
        XCTAssertTrue(fm.fileExists(atPath: film + "/Army of Darkness (1993) {edition-Theatrical Cut}.mkv"))
    }
}
