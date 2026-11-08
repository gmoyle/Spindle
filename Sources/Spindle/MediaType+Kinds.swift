import Foundation

/// The detected disc kind, the same type everywhere (drive, job, ripper).
typealias DiscKind = MediaRipper.MediaType

extension MediaRipper.MediaType {

    var displayName: String {
        switch self {
        case .dvd: return "DVD"
        case .ultraHDDVD: return "Ultra HD DVD"
        case .hddvd: return "HD DVD"
        case .bluray: return "Blu-ray"
        case .bluray4K: return "4K Blu-ray"
        case .audioCD: return "Audio CD"
        case .photoDisc: return "Photo Disc"
        case .dataDisc: return "Data Disc"
        case .unknown: return "Unknown"
        }
    }

    /// Movie / TV discs, ripped to MKV.
    var isVideo: Bool {
        switch self {
        case .dvd, .ultraHDDVD, .hddvd, .bluray, .bluray4K: return true
        case .audioCD, .photoDisc, .dataDisc, .unknown: return false
        }
    }

    /// Whether this version of Spindle has an importer for the kind. Kinds that
    /// are recognized but not importable yet are reported and left in the drive.
    var isImportSupported: Bool { self != .unknown }

    var defaultPriority: ConversionQueue.JobPriority {
        switch self {
        case .bluray4K: return .high
        case .bluray, .hddvd, .unknown: return .normal
        case .dvd, .ultraHDDVD: return .low
        case .audioCD, .photoDisc, .dataDisc: return .normal
        }
    }

    /// The library a disc of this kind is filed into. Video discs are split into
    /// Movies or TV Shows from their title structure at the end of the rip, so
    /// they have no fixed library here.
    var library: LibraryKind? {
        switch self {
        case .audioCD: return .music
        case .photoDisc: return .photos
        case .dataDisc: return .importedDiscs
        case .dvd, .ultraHDDVD, .hddvd, .bluray, .bluray4K, .unknown: return nil
        }
    }
}
