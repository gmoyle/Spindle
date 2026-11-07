# Spindle Roadmap

Spindle (formerly AutoRip2MKV) is turning from a DVD/Blu-ray ripper into a media
library companion: insert any disc, and its contents land in the right library,
named and organized, with nothing to click. The same goes for folders, USB drives,
camera cards and an Apple Photos library, once you point Spindle at them.

Spindle works with Plex, Jellyfin and Emby folder layouts, but isn't tied to any of
them.

## Where it stands (v2.1)

- Hands-free DVD and Blu-ray ripping: auto-rip on insert, eject when the read
  finishes, background encoding, already-ripped discs skipped
- DVD seamless branching, damaged-sector recovery, MakeMKV for Blu-ray/UHD with
  in-app updates
- Movies / TV Shows routing by title structure, with a review queue

## Decisions

| Question | Decision |
|----------|----------|
| Name | **Spindle** (no media-server names in the product name) |
| Music format | **FLAC** |
| CD reading | Fast (macOS's own CD reading); verification such as AccurateRip later |
| Photo destination | **Ask the first time** a photo disc is inserted: a library folder, Apple Photos, or both |
| Phase order | 0 → 1 → 2 → 3 → 4 → 5 → 6 |
| USB drives and camera cards | Never imported automatically; Spindle asks, with "always for this device" |

## Phase 0: Rename to Spindle

- Package, module, app name, bundle ID (`com.gmoyle.spindle`), window title,
  notifications, DMG and release workflow
- Settings, rip history and logs migrated on first launch from the old bundle ID
  and `~/Library/Application Support/AutoRip2MKV-Mac`
- Repository renamed to `gmoyle/Spindle`

## Phase 1: Groundwork ✅

Done. The importer interface is the existing two-step `MediaRipper` contract: read the
disc while it's needed, then run staged encodes after eject. Each disc kind adds a
`MediaRipper+Kind.swift` extension rather than a separate protocol.

- **Disc kinds**: replace the video-only media type with a disc kind decided from
  the disc's contents: video DVD, Blu-ray, HD DVD, audio CD, photo disc,
  home-video disc, data disc
- **Importers**: one importer per disc kind behind a shared interface. The queue,
  retries, local staging, eject, sleep prevention and rip history stay shared
- **Libraries**: a library root per kind (Movies, TV Shows, Music, Photos, Home
  Videos, Imported Discs), each set in Settings
- **Metadata providers**: one interface for OMDb, TMDB and MusicBrainz

## Phase 2: Music CDs ✅

Done, except the review queue for unknown CDs: they're ripped as
`Unknown Artist/Unknown Album (<disc ID>)` and can be renamed by hand for now.
Near matches from MusicBrainz are only used when every track length agrees.

- Read the AIFF tracks macOS exposes for a mounted audio CD; use `.TOC.plist`
  for the track layout
- Compute the MusicBrainz disc ID from the TOC; look up album, artist, year,
  track titles, disc number in a set
- Cover art from the Cover Art Archive
- Encode to FLAC with full tags and embedded art
- File as `Music/Artist/Album (Year)/01 - Title.flac`
  (`Disc 2/` folders for multi-disc sets)
- Unknown CDs: rip as `Unknown Artist/Unknown Album (date)` and add to the review
  queue

## Phase 3: TV series ✅

- ✅ Movie and TV lookups use TMDB when you add a key, with OMDb as the fallback
- ✅ Find the series and season from the disc label; map the disc's titles to
  episodes in disc order
- ✅ Remember series across discs, so disc 2 continues where disc 1 stopped
- ✅ Skip "play all" titles that join every episode
- ✅ File as `TV Shows/Show (Year)/Season 01/Show (Year) - S01E05 - Title.mkv`;
  unsure rips go to the review queue with the reason
- Not yet: editing the proposed episode numbers in the review window, using
  episode runtimes to place a disc whose earlier discs weren't imported, and
  splitting a title that holds two episodes

## Phase 4: Photo, home-video and data discs

- **Photo discs** (JPEG/HEIC/RAW files, `DCIM`, Kodak Picture CD): copy with
  checksum verification, organize by photo date as `Photos/2004/2004-07-14/`,
  skip duplicates of photos already imported. Destination chosen the first time
  (folder, Apple Photos, or both)
- **Home-video discs** (camcorder or burned DVDs with no commercial title):
  rip to a Home Videos library, named by date
- **Other data discs**: copy as-is into `Imported Discs/<disc name>/`

## Phase 5: Import from folders, USB drives and Apple Photos

Discs stay automatic. Other sources are imported when you ask, and go through the
same classifier, importers, libraries, duplicate check and history as discs.

- **Import…**: a File menu command and button, plus dropping a folder or files on
  the window or Dock icon. Spindle sorts what it finds by file type:
  - a `VIDEO_TS` / `BDMV` folder or an ISO: ripped like a disc
  - video files (MKV, MP4, MOV, AVI): filed into Movies / TV Shows (or Home
    Videos for camera clips), remuxed rather than re-encoded where possible
  - music files (FLAC, ALAC, MP3, AAC): tagged and filed into Music, copied as
    they are (no re-encode); a lossless rip in WAV/AIFF is converted to FLAC
  - photos: the photo importer (dates, duplicates)
  - anything else: left alone and listed in the import summary
- **USB drives and camera cards**: when a non-optical removable volume is mounted
  and holds media, Spindle asks: "Import 312 photos and 4 videos from EOS_DIGITAL?"
  It offers Import, Not now, and Always import from this device, and remembers
  the answer per device (volume UUID). Optionally ejects when done.
- **Apple Photos**: read-only through PhotoKit, after macOS asks for Photos access
  the first time. Exports originals (optionally edited versions too) into the
  Photos library by date, and remembers which photos are already exported, so
  later runs only bring new ones. Optional: re-check daily.
- **Watched inbox folder** (optional): anything dropped into it is imported and
  removed from the inbox once it's safely filed.
- **Never moves or deletes the source**: imports copy; the source is left as it was
  (except the inbox folder, which is emptied once each item is filed).

## Phase 6: Companion features

- Ask the local media server to rescan the affected library after each import
  (Plex API with the server token; Jellyfin/Emby later)
- Activity view: an import history of what came in, where it went, and what
  needs review

## Later

- Two-way Apple Photos sync (filing library photos back into Photos)

- AccurateRip verification for audio CDs
- Secure (paranoia-style) CD reading for scratched discs
- Subtitles and artwork for TV episodes
