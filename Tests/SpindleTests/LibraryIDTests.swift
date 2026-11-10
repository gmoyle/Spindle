import XCTest
@testable import Spindle

/// Films are filed with their IMDb (or TMDB) id in the name, so Plex matches
/// the film Spindle identified instead of searching by title again.
final class LibraryIDTests: XCTestCase {

    // MARK: - Names

    func testLibraryNameCarriesTheID() {
        let imdb = MovieMatch(title: "Army of Darkness", year: "1993", imdbID: "tt0106308")
        XCTAssertEqual(imdb.libraryName, "Army of Darkness (1993) {imdb-tt0106308}")
        let tmdb = MovieMatch(title: "Army of Darkness", year: "1993", tmdbID: "766")
        XCTAssertEqual(tmdb.libraryName, "Army of Darkness (1993) {tmdb-766}")
        XCTAssertEqual(MovieMatch(title: "Heat", year: "1995").libraryName, "Heat (1995)")
        XCTAssertEqual(MovieMatch(title: "Heat", year: "1995", imdbID: "N/A").libraryName, "Heat (1995)")
    }

    func testReadingLibraryNames() {
        let name = "Army of Darkness (1993) {imdb-tt0106308} {edition-Director's Cut}"
        XCTAssertEqual(MovieMatch.displayName(ofLibraryName: name), "Army of Darkness (1993)")
        XCTAssertEqual(MovieMatch.idTag(inLibraryName: name), "imdb-tt0106308")
        XCTAssertEqual(MovieMatch.idTag(inLibraryName: "Film (2000) {tmdb-42}"), "tmdb-42")
        XCTAssertNil(MovieMatch.idTag(inLibraryName: "Film (2000) {edition-Redux}"))
    }

    func testProvidersKeepTheirIDs() {
        let omdb = #"{"Response":"True","Search":[{"Title":"Heat","Year":"1995","imdbID":"tt0113277"}]}"#
        XCTAssertEqual(OMDbProvider.parseSearchResponse(Data(omdb.utf8)).first?.imdbID, "tt0113277")
        let tmdb = #"{"results":[{"id":949,"title":"Heat","release_date":"1995-12-15"}]}"#
        XCTAssertEqual(TMDBProvider.parseMovieSearch(Data(tmdb.utf8)).first?.tmdbID, "949")
    }

    func testFolderNamesKeepTheIDAfterTheYear() {
        let info = OutputOrganizer.parse(displayName: "Heat (1995) {imdb-tt0113277}", contentType: .unknown)
        XCTAssertEqual(info.title, "Heat")
        XCTAssertEqual(info.year, 1995)
        XCTAssertEqual(info.plexName, "Heat (1995) {imdb-tt0113277}")
        XCTAssertEqual(OutputOrganizer.parse(displayName: "Heat (1995)", contentType: .unknown).plexName,
                       "Heat (1995)")
    }

    func testNFONamesTheFilmAndItsID() {
        let nfo = MovieNFO.contents(forLibraryName: "Bill & Ted's Excellent Adventure (1989) {imdb-tt0096928}")
        XCTAssertTrue(nfo.contains("<title>Bill &amp; Ted's Excellent Adventure</title>"))
        XCTAssertTrue(nfo.contains("<year>1989</year>"))
        XCTAssertTrue(nfo.contains("<uniqueid type=\"imdb\" default=\"true\">tt0096928</uniqueid>"))
        XCTAssertFalse(MovieNFO.contents(forLibraryName: "Home Movie").contains("uniqueid"))
    }

    // MARK: - Filing

    private var root: String!
    private var library: String!
    private var history: RipHistoryStore!
    private let fm = FileManager.default

    override func setUp() {
        super.setUp()
        root = (NSTemporaryDirectory() as NSString).appendingPathComponent("ids-\(UUID().uuidString)")
        library = (root as NSString).appendingPathComponent("Movies")
        try? fm.createDirectory(atPath: library, withIntermediateDirectories: true)
        history = RipHistoryStore(fileURL: URL(fileURLWithPath: root).appendingPathComponent("history.json"))
    }

    override func tearDown() {
        try? fm.removeItem(atPath: root)
        super.tearDown()
    }

    @discardableResult
    private func makeRip(in parent: String, name: String, label: String, content: String) -> String {
        let folder = (parent as NSString).appendingPathComponent(name)
        try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        fm.createFile(atPath: (folder as NSString).appendingPathComponent("\(name).mkv"), contents: Data(content.utf8))
        let info = try? JSONSerialization.data(withJSONObject: ["movie_name": label])
        fm.createFile(atPath: (folder as NSString).appendingPathComponent("disc_info.json"), contents: info)
        return folder
    }

    private func staging() -> String {
        let path = (root as NSString).appendingPathComponent("staging-\(UUID().uuidString)")
        try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func names(_ folder: String) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).filter { $0 != ".DS_Store" }.sorted()
    }

    func testAnOlderFolderWithoutTheIDGetsIt() throws {
        makeRip(in: library, name: "Heat (1995)", label: "HEAT", content: "old")
        let rip = makeRip(in: staging(), name: "Heat (1995) {imdb-tt0113277}", label: "HEAT_DC", content: "dc")

        let destination = try LibraryFiles.fileFolder(rip, into: library, discIdentity: "new",
                                                      asEditions: true, history: history)

        XCTAssertEqual(names(library), ["Heat (1995) {imdb-tt0113277}"], "one folder for the film")
        XCTAssertEqual((destination as NSString).lastPathComponent, "Heat (1995) {imdb-tt0113277}")
        XCTAssertEqual(try String(contentsOfFile: destination + "/Heat (1995) {imdb-tt0113277}.mkv"), "old")
        XCTAssertEqual(try String(contentsOfFile: destination
                                  + "/Heat (1995) {imdb-tt0113277} {edition-Director's Cut}.mkv"), "dc")
    }

    func testARipWithoutAnIDJoinsTheFilmsTaggedFolder() throws {
        makeRip(in: library, name: "Heat (1995) {imdb-tt0113277}", label: "HEAT", content: "first")
        let rip = makeRip(in: staging(), name: "Heat (1995)", label: "HEAT_EXTENDED", content: "typed")

        let destination = try LibraryFiles.fileFolder(rip, into: library, discIdentity: "new",
                                                      asEditions: true, history: history)

        XCTAssertEqual(names(library), ["Heat (1995) {imdb-tt0113277}"])
        XCTAssertEqual(try String(contentsOfFile: destination
                                  + "/Heat (1995) {imdb-tt0113277} {edition-Extended Edition}.mkv"), "typed")
    }

    func testDifferentIDsAreDifferentFilms() throws {
        makeRip(in: library, name: "Heat (1995) {imdb-tt0113277}", label: "HEAT", content: "one")
        let rip = makeRip(in: staging(), name: "Heat (1995) {imdb-tt9999999}", label: "HEAT", content: "two")

        _ = try LibraryFiles.fileFolder(rip, into: library, discIdentity: "new", asEditions: true, history: history)

        XCTAssertEqual(names(library), ["Heat (1995) {imdb-tt0113277}", "Heat (1995) {imdb-tt9999999}"])
    }

    func testChoosingAFilmGivesItsIDToTheOlderFolder() throws {
        makeRip(in: library, name: "Heat (1995)", label: "HEAT", content: "old")
        let guess = makeRip(in: library, name: "Heat (1986)", label: "HEAT_DC", content: "dc")
        MovieNFO.write(in: guess, base: "Heat (1986)")

        let result = try TitleRetitler.retitle(folder: guess, from: "Heat (1986)",
                                               to: "Heat (1995) {imdb-tt0113277}", history: history)

        XCTAssertEqual(names(library), ["Heat (1995) {imdb-tt0113277}"])
        XCTAssertEqual(try String(contentsOfFile: result + "/Heat (1995) {imdb-tt0113277}.mkv"), "old")
        let dc = result + "/Heat (1995) {imdb-tt0113277} {edition-Director's Cut}"
        XCTAssertEqual(try String(contentsOfFile: dc + ".mkv"), "dc")
        XCTAssertTrue(try String(contentsOfFile: dc + ".nfo").contains("tt0113277"), "nfo follows the new film")
    }
}
