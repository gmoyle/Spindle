import XCTest
@testable import Spindle

/// Two drives read two discs at once: one read per drive, each disc under its
/// own title, staged apart, and MakeMKV never enumerates drives while another
/// drive is being read.
final class ParallelDrivesTests: XCTestCase {

    private func config() -> MediaRipper.RippingConfiguration {
        MediaRipper.RippingConfiguration(
            outputDirectory: "/tmp/output", selectedTitles: [], videoCodec: .h264, audioCodec: .aac,
            quality: .medium, includeSubtitles: true, includeChapters: true, mediaType: nil)
    }

    private func jobs(_ sources: [String], priority: [ConversionQueue.JobPriority]? = nil)
        -> [ConversionQueue.ConversionJob] {
        let queue = ConversionQueue(testMode: true)
        for (i, source) in sources.enumerated() {
            _ = queue.addJob(sourcePath: source, outputDirectory: "/tmp/output", configuration: config(),
                             mediaType: .dvd, discTitle: "Disc \(i)", priority: priority?[i] ?? .normal)
            Thread.sleep(forTimeInterval: 0.002)  // distinct addedTime, FIFO order
        }
        return queue.getAllJobs()
    }

    // MARK: - Queue

    func testTwoDrivesStartTogether() {
        let all = jobs(["/Volumes/HEAT", "/Volumes/ALIENS"])
        XCTAssertEqual(ConversionQueue.jobsToStart(all, reading: []), all.map(\.id))
    }

    func testOneReadPerDrive() {
        let all = jobs(["/Volumes/HEAT", "/Volumes/HEAT"])
        XCTAssertEqual(ConversionQueue.jobsToStart(all, reading: []), [all[0].id])
    }

    func testABusyDriveWaitsWhileTheOtherStarts() {
        let all = jobs(["/Volumes/HEAT", "/Volumes/ALIENS"])
        XCTAssertEqual(ConversionQueue.jobsToStart(all, reading: ["/Volumes/HEAT"]), [all[1].id])
        XCTAssertEqual(ConversionQueue.jobsToStart(all, reading: ["/Volumes/HEAT", "/Volumes/ALIENS"]), [])
    }

    func testHigherPriorityJobOfADriveGoesFirst() {
        let all = jobs(["/Volumes/HEAT", "/Volumes/HEAT"], priority: [.normal, .high])
        XCTAssertEqual(ConversionQueue.jobsToStart(all, reading: []), [all[1].id])
    }

    // MARK: - Drive reads

    func testReadsKnowAboutEachOther() {
        let reads = DiscReads()
        XCTAssertFalse(reads.othersReading(than: "/Volumes/HEAT"))
        reads.begin("/Volumes/HEAT")
        XCTAssertFalse(reads.othersReading(than: "/Volumes/HEAT/BDMV"), "a path inside its own disc")
        XCTAssertFalse(reads.earlierReading(than: "/Volumes/HEAT"))
        reads.begin("/Volumes/HEAT 1")
        XCTAssertTrue(reads.othersReading(than: "/Volumes/HEAT"), "HEAT 1 is another disc, not inside HEAT")
        XCTAssertTrue(reads.earlierReading(than: "/Volumes/HEAT 1"))
        XCTAssertFalse(reads.earlierReading(than: "/Volumes/HEAT"))
        reads.end("/Volumes/HEAT")
        XCTAssertFalse(reads.othersReading(than: "/Volumes/HEAT 1"))
        XCTAssertFalse(reads.earlierReading(than: "/Volumes/HEAT 1"))
    }

    func testMakeMKVOpensByDeviceOnlyWhileAnotherDriveIsRead() throws {
        let reads = DiscReads()
        reads.begin("/")
        XCTAssertNil(MakeMKVBackend.deviceSpec(for: "/", reads: reads), "alone: enumerate as before")
        reads.begin("/Volumes/OTHER")
        let bsd = try XCTUnwrap(MakeMKVBackend.bsdName(forMountPoint: "/"))
        XCTAssertEqual(MakeMKVBackend.deviceSpec(for: "/", reads: reads), "dev:/dev/r\(bsd)")
    }

    // MARK: - Staging and progress

    func testEachRipStagesInItsOwnFolder() {
        let first = MediaRipper(), second = MediaRipper()
        let name = "/Movies/Army of Darkness (1993)/Army of Darkness (1993).mkv"
        XCTAssertNotEqual(first.encodingStagingPath(for: name), second.encodingStagingPath(for: name))
        XCTAssertTrue(first.stagingDirectoriesToRemove.contains(first.stagingFolder))
        first.removeStagingDirectories()
        second.removeStagingDirectories()
    }

    func testProgressLine() {
        let mb: (Int64) -> String = { "\($0 / 1_000_000) MB" }
        XCTAssertEqual(MainViewController.readingLine(titles: ["Heat"], progress: [0.5], sizes: [4_000_000_000],
                                                      formatBytes: mb), "2000 MB / 4000 MB  (50%)")
        XCTAssertEqual(MainViewController.readingLine(titles: ["Heat", "Aliens"], progress: [0.41, 0.12],
                                                      sizes: [nil, nil], formatBytes: mb), "Heat 41% · Aliens 12%")
        XCTAssertEqual(MainViewController.discBytes(inStatus: "Reading 1000 sectors for title 1 via libdvdcss..."),
                       2_048_000)
        XCTAssertNil(MainViewController.discBytes(inStatus: "Opening disc"))
    }
}
