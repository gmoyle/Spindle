import XCTest
@testable import Spindle

final class TVDiscLabelTests: XCTestCase {

    private func label(_ name: String) -> TVDiscLabel { TVDiscLabel(volumeName: name) }

    func testSeasonAndDiscForms() {
        XCTAssertEqual(label("THE_OFFICE_S2_D3"), TVDiscLabel(query: "THE OFFICE", season: 2, disc: 3))
        XCTAssertEqual(label("SEINFELD_SEASON_3_DISC_1"), TVDiscLabel(query: "SEINFELD", season: 3, disc: 1))
        XCTAssertEqual(label("LOST_S1D4"), TVDiscLabel(query: "LOST", season: 1, disc: 4))
        XCTAssertEqual(label("BREAKING_BAD_SEASON1_DISC2"), TVDiscLabel(query: "BREAKING BAD", season: 1, disc: 2))
        XCTAssertEqual(label("Friends Season 1 Disc 2"), TVDiscLabel(query: "Friends", season: 1, disc: 2))
    }

    func testDiscOnly() {
        XCTAssertEqual(label("FIREFLY_D1"), TVDiscLabel(query: "FIREFLY", season: nil, disc: 1))
        XCTAssertEqual(label("FIREFLY"), TVDiscLabel(query: "FIREFLY", season: nil, disc: nil))
    }

    func testNumbersInTheTitleStay() {
        XCTAssertEqual(label("24_SEASON_2_DISC_1"), TVDiscLabel(query: "24", season: 2, disc: 1))
        XCTAssertEqual(label("THE_WIRE_WS_D2").query, "THE WIRE")
    }

    func testShowKeyIgnoresCase() {
        XCTAssertEqual(label("FIREFLY_D1").showKey, label("Firefly_D2").showKey)
    }
}

final class TVEpisodeSelectionTests: XCTestCase {

    private func select(_ minutes: [Double]) -> TVEpisodeSelection? {
        TVEpisodeSelection.select(durationsSeconds: minutes.map { $0 * 60 })
    }

    func testEpisodesPlayAllAndExtras() {
        // Four episodes, "play all" (all four), a 10-minute featurette, a menu clip.
        let selection = select([44, 176.5, 43, 45, 44, 10, 1])
        XCTAssertEqual(selection?.episodes, [0, 2, 3, 4])
        XCTAssertEqual(selection?.playAll, [1])
        XCTAssertEqual(selection?.extras, [5])
    }

    func testDoubleLengthPilotIsAnEpisode() {
        let selection = select([86, 44, 43, 45, 44])
        XCTAssertEqual(selection?.episodes, [0, 1, 2, 3, 4])
        XCTAssertEqual(selection?.playAll, [])
    }

    func testDuplicatesMarkedZeroAreIgnored() {
        let selection = select([22, 22, 0, 23, 22])
        XCTAssertEqual(selection?.episodes, [0, 1, 3, 4])
    }

    func testMovieDiscIsNotTV() {
        XCTAssertNil(select([118, 4, 2, 7]))
    }

    func testDVDDuplicateTitlesAreDropped() {
        func title(_ number: Int, minutes: Double, cells: [ClosedRange<UInt32>]) -> DVDTitle {
            let t = DVDTitle(number: number, vtsNumber: 1, vtsTitleNumber: number, startSector: 0,
                             chapters: 1, angles: 1, duration: minutes * 60)
            t.cellRanges = cells
            return t
        }
        let titles = [title(1, minutes: 44, cells: [0...100]), title(2, minutes: 44, cells: [0...100]),
                      title(3, minutes: 43, cells: [101...200]), title(4, minutes: 45, cells: [201...300])]
        XCTAssertEqual(MediaRipper.tvEpisodeSelection(for: titles)?.episodes, [0, 2, 3])
    }
}

final class TVEpisodePlannerTests: XCTestCase {

    typealias Disc = TVEpisodePlanner.DiscRecord

    private func plan(disc: Int?, identity: String = "new", count: Int = 4, total: Int? = 14,
                      previous: [Disc] = [], strict: Bool = true) -> TVEpisodePlanner.Plan {
        TVEpisodePlanner.firstEpisode(season: 1, disc: disc, identity: identity, episodeCount: count,
                                      seasonEpisodeTotal: total, previous: previous, strict: strict)
    }

    private let disc1 = Disc(identity: "d1", season: 1, disc: 1, firstEpisode: 1, episodeCount: 4)

    func testFirstDiscStartsAtOne() {
        XCTAssertEqual(plan(disc: 1), .start(1))
    }

    func testNextDiscContinuesAfterThePreviousOne() {
        XCTAssertEqual(plan(disc: 2, previous: [disc1]), .start(5))
    }

    func testMissingEarlierDiscIsUnsureUnlessAskedToGuess() {
        guard case .unsure = plan(disc: 3, previous: [disc1]) else { return XCTFail("should be unsure") }
        XCTAssertEqual(plan(disc: 3, previous: [disc1], strict: false), .start(5))
        XCTAssertEqual(plan(disc: 3, strict: false), .start(9))
    }

    func testReRipKeepsItsEpisodes() {
        let disc2 = Disc(identity: "d2", season: 1, disc: 2, firstEpisode: 5, episodeCount: 4)
        XCTAssertEqual(plan(disc: 2, identity: "d2", previous: [disc1, disc2]), .start(5))
    }

    func testSameDiscNumberFromAnotherDiscIsUnsure() {
        guard case .unsure = plan(disc: 1, previous: [disc1]) else { return XCTFail("should be unsure") }
    }

    func testTooManyEpisodesForTheSeasonIsUnsure() {
        guard case .unsure = plan(disc: 2, count: 12, previous: [disc1]) else { return XCTFail("should be unsure") }
    }

    func testUnnumberedDiscsAreTakenInOrder() {
        XCTAssertEqual(plan(disc: nil), .start(1))
        XCTAssertEqual(plan(disc: nil, previous: [disc1]), .start(5))
    }
}

final class TVMetadataParsingTests: XCTestCase {

    func testTMDBSeriesSearch() {
        let json = #"{"results":[{"id":1437,"name":"Firefly","first_air_date":"2002-09-20"}]}"#
        XCTAssertEqual(TMDBProvider.parseSeriesSearch(Data(json.utf8)),
                       [SeriesMatch(id: "1437", name: "Firefly", year: "2002", provider: "TMDB")])
    }

    func testTMDBSeasonFromAppendedResponse() {
        let json = """
        {"name":"Firefly","number_of_seasons":1,"season/1":{"episodes":[
          {"episode_number":1,"name":"Serenity","runtime":86},
          {"episode_number":2,"name":"The Train Job","runtime":43}]}}
        """
        let season = TMDBProvider.parseSeason(Data(json.utf8), number: 1)
        XCTAssertEqual(season?.seasonCount, 1)
        XCTAssertEqual(season?.episode(2), SeasonListing.Episode(number: 2, title: "The Train Job", runtimeMinutes: 43))
    }

    func testTMDBMovieSearch() {
        let json = #"{"results":[{"title":"The Goonies","release_date":"1985-06-07"}]}"#
        XCTAssertEqual(TMDBProvider.parseMovieSearch(Data(json.utf8)), [MovieMatch(title: "The Goonies", year: "1985")])
    }

    func testOMDbSeries() {
        let search = #"{"Search":[{"Title":"Firefly","Year":"2002–2003","imdbID":"tt0303461","Type":"series"}],"Response":"True"}"#
        XCTAssertEqual(OMDbProvider.parseSeriesSearch(Data(search.utf8)),
                       [SeriesMatch(id: "tt0303461", name: "Firefly", year: "2002", provider: "OMDb")])
        let season = """
        {"Title":"Firefly","Season":"1","totalSeasons":"1","Episodes":[
          {"Title":"The Train Job","Episode":"2"},{"Title":"Serenity","Episode":"1"}],"Response":"True"}
        """
        let listing = OMDbProvider.parseSeason(Data(season.utf8), number: 1)
        XCTAssertEqual(listing?.episodes.map(\.title), ["Serenity", "The Train Job"])
        XCTAssertEqual(listing?.seasonCount, 1)
    }

    func testEpisodeFileNames() {
        let firefly = SeriesMatch(id: "1", name: "Firefly", year: "2002", provider: "TMDB")
        XCTAssertEqual(TVLibraryNaming.episodeFileName(series: firefly, season: 1, episode: 2, title: "The Train Job"),
                       "Firefly (2002) - S01E02 - The Train Job.mkv")
        XCTAssertEqual(TVLibraryNaming.episodeFileName(series: firefly, season: 1, episode: 3, title: "What? Now/Then"),
                       "Firefly (2002) - S01E03 - What_ Now_Then.mkv")
        XCTAssertEqual(TVLibraryNaming.seasonFolder(for: firefly, season: 1, in: "/TV"), "/TV/Firefly (2002)/Season 01")
    }
}

/// Filing a ripped disc into the TV library with a fake provider.
final class TVLibraryFilerTests: XCTestCase {

    private struct FakeProvider: TVMetadataProvider {
        let name = "Fake"
        func searchSeries(query: String, completion: @escaping ([SeriesMatch]) -> Void) {
            completion(query.lowercased() == "firefly"
                ? [SeriesMatch(id: "1437", name: "Firefly", year: "2002", provider: "Fake")] : [])
        }
        func season(_ number: Int, of series: SeriesMatch, completion: @escaping (SeasonListing?) -> Void) {
            let titles = ["Serenity", "The Train Job", "Bushwhacked", "Shindig", "Safe", "Our Mrs. Reynolds"]
            completion(SeasonListing(season: 1, seasonCount: 1, episodes: titles.enumerated().map {
                SeasonListing.Episode(number: $0.offset + 1, title: $0.element, runtimeMinutes: 43)
            }))
        }
    }

    private var temp: URL!
    private var originalTVRoot: String!
    private var memory: TVSeriesMemory!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("tvfiler-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        originalTVRoot = SettingsManager.shared.tvShowsRootDirectory
        SettingsManager.shared.tvShowsRootDirectory = temp.appendingPathComponent("TV").path
        memory = TVSeriesMemory(fileURL: temp.appendingPathComponent("memory.json"))
    }

    override func tearDownWithError() throws {
        SettingsManager.shared.tvShowsRootDirectory = originalTVRoot
        try? FileManager.default.removeItem(at: temp)
    }

    /// A rip folder with `episodes` episode files and one extra.
    private func rip(_ name: String, episodes: Int) throws -> (String, [RippedTitle]) {
        let folder = temp.appendingPathComponent(name).path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: URL(fileURLWithPath: folder + "/disc_info.json"))
        var titles: [RippedTitle] = []
        for n in 1...episodes + 1 {
            let path = folder + String(format: "/Title %02d.mkv", n)
            try Data("video \(n)".utf8).write(to: URL(fileURLWithPath: path))
            titles.append(RippedTitle(path: path, durationSeconds: n <= episodes ? 2600 : 600, isEpisode: n <= episodes))
        }
        return (folder, titles)
    }

    private func file(_ folder: String, _ disc: String, _ titles: [RippedTitle]) -> TVLibraryFiler.Outcome {
        TVLibraryFiler.file(folderPath: folder, discName: disc, discIdentity: disc + "#id", titles: titles,
                            provider: FakeProvider(), memory: memory)
    }

    func testFilesTwoDiscsInOrder() throws {
        let (folder1, titles1) = try rip("FIREFLY_D1", episodes: 3)
        guard case .filed(_, let season) = file(folder1, "FIREFLY_D1", titles1) else { return XCTFail("not filed") }
        XCTAssertEqual(season, temp.appendingPathComponent("TV/Firefly (2002)/Season 01").path)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: season).sorted(), [
            "Firefly (2002) - S01E01 - Serenity.mkv",
            "Firefly (2002) - S01E02 - The Train Job.mkv",
            "Firefly (2002) - S01E03 - Bushwhacked.mkv"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: temp.appendingPathComponent("TV/Firefly (2002)/Featurettes").path), ["FIREFLY_D1 - Title 04.mkv"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder1), "the emptied rip folder is removed")

        let (folder2, titles2) = try rip("FIREFLY_D2", episodes: 3)
        guard case .filed = file(folder2, "FIREFLY_D2", titles2) else { return XCTFail("disc 2 not filed") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: season + "/Firefly (2002) - S01E06 - Our Mrs. Reynolds.mkv"))
    }

    func testUnknownShowIsLeftForReview() throws {
        let (folder, titles) = try rip("NOT_A_SHOW_D1", episodes: 3)
        guard case .unsure = file(folder, "NOT_A_SHOW_D1", titles) else { return XCTFail("should be unsure") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: titles[0].path), "nothing moves when unsure")
    }

    func testDiscTwoFirstWaitsForReview() throws {
        let (folder, titles) = try rip("FIREFLY_D2", episodes: 3)
        guard case .unsure = file(folder, "FIREFLY_D2", titles) else { return XCTFail("should be unsure") }
    }

    func testRouterQueuesAnUnsureTVRipWithItsReason() throws {
        let routing = (SettingsManager.shared.contentRoutingEnabled, SettingsManager.shared.autoRouteHighConfidence)
        SettingsManager.shared.contentRoutingEnabled = true
        SettingsManager.shared.autoRouteHighConfidence = true
        defer {
            SettingsManager.shared.contentRoutingEnabled = routing.0
            SettingsManager.shared.autoRouteHighConfidence = routing.1
        }
        let queue = PendingRoutingQueue(defaults: UserDefaults(suiteName: "tv-\(UUID().uuidString)")!)
        let (folder, titles) = try rip("FIREFLY_D2", episodes: 3)
        let status = ContentRouter.handleCompletedRip(
            folderPath: folder, discName: "FIREFLY_D2", discIdentity: "x",
            titleDurationsSeconds: [2600, 2600, 2600, 600], rippedTitles: titles, queue: queue,
            tvFiler: { _, _, _, _, _ in .unsure("disc 1 missing") })
        XCTAssertTrue(status.contains("disc 1 missing"))
        XCTAssertEqual(queue.items.first?.note, "disc 1 missing")
        XCTAssertEqual(queue.items.first?.rippedTitles, titles)
    }
}
