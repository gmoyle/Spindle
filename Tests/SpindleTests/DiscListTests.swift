import XCTest
@testable import Spindle

/// The main window's Discs list: discs in the drives and every rip, each with
/// its own Cancel.
final class DiscListTests: XCTestCase {

    private func job(_ title: String, source: String, status: ConversionQueue.JobStatus,
                     added: TimeInterval) -> ConversionQueue.ConversionJob {
        let config = MediaRipper.RippingConfiguration(
            outputDirectory: "/tmp", selectedTitles: [], videoCodec: .h264, audioCodec: .aac,
            quality: .high, includeSubtitles: true, includeChapters: true, mediaType: nil)
        var job = ConversionQueue.ConversionJob(sourcePath: source, outputDirectory: "/tmp",
                                                configuration: config, mediaType: .dvd, discTitle: title)
        job.status = status
        job.addedTime = Date(timeIntervalSince1970: added)
        return job
    }

    func testIdleDiscsComeFirstThenRipsNewestFirst() {
        let drives = [OpticalDrive(mountPoint: "/Volumes/BOFFDEAD", name: "BOFFDEAD", type: .dvd,
                                   devicePath: "/dev/disk4"),
                      OpticalDrive(mountPoint: "/Volumes/ENEMY", name: "ENEMY", type: .dvd,
                                   devicePath: "/dev/disk5")]
        let jobs = [job("Old Film (1990)", source: "/Volumes/OLD", status: .completed, added: 1),
                    job("Enemy of the State (1998)", source: "/Volumes/ENEMY", status: .extracting, added: 2)]
        let rows = DiscListRow.rows(drives: drives, jobs: jobs)

        XCTAssertEqual(rows.map(\.disc), ["BOFFDEAD", "ENEMY", "OLD"], "a disc being ripped is listed once")
        XCTAssertNil(rows[0].jobId)
        XCTAssertFalse(rows[0].canCancel)
        XCTAssertTrue(rows[1].canCancel, "a disc being read can be cancelled")
        XCTAssertEqual(rows[1].title, "Enemy of the State (1998)")
        XCTAssertFalse(rows[2].canCancel, "a finished rip can't")
        XCTAssertEqual(rows[2].progress, "100%")
    }

    func testOnlyQueuedReadingOrEncodingRipsCanBeCancelled() {
        let statuses: [(ConversionQueue.JobStatus, Bool)] = [
            (.pending, true), (.extracting, true), (.extracted, true), (.converting, true),
            (.completed, false), (.cancelled, false), (.failed(ConversionQueueError.sourceNotFound), false)
        ]
        for (status, cancellable) in statuses {
            let row = DiscListRow.rows(drives: [], jobs: [job("A", source: "/Volumes/A", status: status, added: 1)])
            XCTAssertEqual(row.first?.canCancel, cancellable, "\(status)")
        }
    }

    func testAFinishedRipDoesntHideTheDiscStillInTheDrive() {
        let drives = [OpticalDrive(mountPoint: "/Volumes/A", name: "A", type: .dvd, devicePath: "/dev/disk4")]
        let rows = DiscListRow.rows(drives: drives,
                                    jobs: [job("A (2000)", source: "/Volumes/A", status: .completed, added: 1)])
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows[0].status.hasPrefix("In drive"))
    }

    // MARK: Lines at the top

    func testEachDiscGetsItsOwnLineAndOnlyARipHasACancel() {
        let drives = [OpticalDrive(mountPoint: "/Volumes/BOFFDEAD", name: "BOFFDEAD", type: .dvd,
                                   devicePath: "/dev/disk4"),
                      OpticalDrive(mountPoint: "/Volumes/ENEMY", name: "ENEMY", type: .bluray,
                                   devicePath: "/dev/disk5")]
        let reading = job("Enemy of the State (1998)", source: "/Volumes/ENEMY", status: .extracting, added: 2)
        let lines = DiscStatusLine.lines(
            drives: drives, jobs: [job("Old", source: "/Volumes/BOFFDEAD", status: .completed, added: 1), reading],
            titles: ["/Volumes/BOFFDEAD": "Better Off Dead (1985)"], readProgress: [reading.id: 0.4],
            idleStatus: "Ready to rip")

        XCTAssertEqual(lines.count, 2, "one line per disc, not \"2 discs\"")
        XCTAssertTrue(lines[0].text.hasPrefix("Better Off Dead (1985) ("))
        XCTAssertTrue(lines[0].text.hasSuffix(" - Ready to rip"))
        XCTAssertNil(lines[0].jobId, "a finished rip has no Cancel")
        XCTAssertTrue(lines[1].text.hasPrefix("Enemy of the State (1998) ("))
        XCTAssertTrue(lines[1].text.hasSuffix(" - Reading disc… 40%"))
        XCTAssertEqual(lines[1].jobId, reading.id)
    }

    func testAFilmPickedInTheWindowNamesTheLineAndTheRow() {
        let drives = [OpticalDrive(mountPoint: "/Volumes/DVD_VIDEO", name: "DVD_VIDEO", type: .dvd,
                                   devicePath: "/dev/disk4")]
        let reading = job("Untitled Disc 2026-11-13 17-11", source: "/Volumes/DVD_VIDEO",
                          status: .extracting, added: 1)
        let names = [reading.id: "The Amazing Spider-Man 2 (2014)"]
        let line = DiscStatusLine.lines(drives: drives, jobs: [reading], titles: [:], names: names,
                                        readProgress: [:], idleStatus: "Ready to rip").first
        XCTAssertEqual(line?.text.hasPrefix("The Amazing Spider-Man 2 (2014) ("), true)
        XCTAssertEqual(DiscListRow.rows(drives: drives, jobs: [reading], names: names).first?.title,
                       "The Amazing Spider-Man 2 (2014)")
    }

    func testAQueuedOrEncodingDiscSaysSo() {
        let drives = [OpticalDrive(mountPoint: "/Volumes/A", name: "A", type: .dvd, devicePath: "/dev/disk4")]
        for (status, text) in [(ConversionQueue.JobStatus.pending, "Waiting to rip"), (.converting, "Encoding…")] {
            let line = DiscStatusLine.lines(drives: drives, jobs: [job("A (2000)", source: "/Volumes/A",
                                                                      status: status, added: 1)],
                                            titles: [:], readProgress: [:], idleStatus: "Ready to rip").first
            XCTAssertEqual(line?.text.hasSuffix(" - \(text)"), true, "\(status)")
            XCTAssertNotNil(line?.jobId)
        }
    }
}

/// Rips from earlier sessions stay in the Discs list, from the rip history.
final class EarlierRipsListTests: XCTestCase {

    private func entry(_ volume: String, _ title: String, location: String, at time: TimeInterval) -> RipHistoryEntry {
        RipHistoryEntry(discIdentity: "\(volume)#1", volumeName: volume, title: title, settingsFingerprint: [:],
                        outputLocation: location, completedAt: Date(timeIntervalSince1970: time))
    }

    func testEarlierRipsFollowThisSessionsAndAreNamedByTheirFolder() {
        let earlier = [entry("SEVEN", "Scream 7 (2026)", location: "/Movies/Se7en (1995) {tmdb-807}", at: 2),
                       entry("AUDIO_CD", "Rumours", location: "/Music/Fleetwood Mac/Rumours", at: 1)]
        let rows = DiscListRow.rows(drives: [], jobs: [], earlier: earlier)

        XCTAssertEqual(rows.map(\.title), ["Se7en (1995)", "Rumours"],
                       "a renamed rip shows its new name; a folder that isn't a film's keeps the recorded title")
        XCTAssertEqual(rows.map(\.historyIdentity), ["SEVEN#1", "AUDIO_CD#1"])
        XCTAssertFalse(rows[0].canCancel)
        XCTAssertEqual(rows[0].status, "Complete")
    }
}
