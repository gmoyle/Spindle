# Spindle User Guide

This guide covers Spindle v2.1: how a rip works, the main window, the Plex
library workflow, MakeMKV for Blu-ray, and troubleshooting. Every setting is
described in the [Settings Guide](DETAILED_SETTINGS_GUIDE.md); installation is in
the [Installation Guide](INSTALLATION.md).

## Contents

1. [How a rip works](#how-a-rip-works)
2. [Main window](#main-window)
3. [Already-ripped discs](#already-ripped-discs)
4. [Plex libraries and routing](#plex-libraries-and-routing)
5. [DVDs](#dvds)
6. [Blu-ray and MakeMKV](#blu-ray-and-makemkv)
7. [TV series](#tv-series)
8. [Music CDs](#music-cds)
9. [Photo, home-video and data discs](#photo-home-video-and-data-discs)
10. [Encoding](#encoding)
11. [Scripts](#scripts)
12. [Troubleshooting](#troubleshooting)

---

## How a rip works

With the default settings you only insert discs:

1. **Detect.** The app notices the disc as soon as macOS mounts it.
2. **Identify.** It looks up the disc's name on OMDb to get the movie's title and
   year, and checks whether this disc has already been ripped.
3. **Read.** The main movie (and bonus features, if you turned them on) is read
   from the disc at full drive speed into a local cache folder.
4. **Eject.** The disc ejects as soon as the read finishes, so you can insert the
   next one.
5. **Encode.** FFmpeg converts each title to MKV in the background, while the next
   disc reads.
6. **File.** Finished files move into the output folder and then, with content
   routing on, into your Movies or TV Shows library.

The Mac won't idle-sleep while a job is running, because sleep cuts power to USB
drives in the middle of a read.

**Two drives**: with a second drive connected, both discs are read at the same
time, each into its own place in the cache, and each ejects when it's done. Each
drive reads one disc at a time. Encodes still run one after another. While two
discs are reading, the progress line shows both ("Heat 41% · Aliens 12%"), the
log names the disc each line is about, and **Cancel Rip** asks which disc to stop.

## Main window

- **Source**: the drive dropdown lists optical drives (**Refresh** rescans);
  **Browse** picks a disc folder or image instead.
- **Output**: where rips are written before routing.
- **Auto-rip inserted discs**, **Auto-eject after ripping**, **Skip discs already
  ripped**, **Keep this Mac awake and unlocked**: see
  [Settings Guide → Main window](DETAILED_SETTINGS_GUIDE.md#main-window).
- **Settings…**: the Settings window.
- **Review Rips**: appears when rips are waiting for a Movie or TV decision.
- **Start Ripping**: rip the current disc now, even if it was ripped before. While
  a rip runs, it cancels.
- **Queue**: each job shows its phase (reading, then encoding) and progress.
  Right-click a job to **Cancel**, **Retry**, **Reveal in Finder**, or **Remove from List**.
- **Log**: live status and errors. **Hide Log** collapses it.

## Already-ripped discs

The app keeps a record of each disc it has ripped, by a fingerprint of the disc's
contents (not just its name), in
`~/Library/Application Support/Spindle/rip_history.json`. With **Skip discs
already ripped** on, a known disc is ejected without ripping, unless:

- you hold **⌥ Option** while inserting it, or click **Start Ripping**;
- you've changed a setting that affects the output since it was ripped;
- you deleted the folder the rip went to (a folder on a disconnected drive or NAS
  still counts as ripped);
- the disc's rip is still waiting under **Review Rips** (then it's skipped, not
  ripped twice).

## Plex libraries and routing

Rips are named `Movie (Year)/Movie (Year).mkv`, from a lookup on the disc's label.
Labels can't hold apostrophes, so `OCEANS_ELEVEN_2001` is also searched as "Ocean's
Eleven", and a year on the label picks between a film and its remake.

**Which film is this?** When the lookup isn't sure (nothing has the label's exact
title, or two films share it and the label has no year), the disc starts ripping
anyway under the best guess, and a window lists the matches with their posters,
plus the disc's own name. Pick one and the rip's folder and files are renamed:
straight away if the rip has finished, or when it does. Ignore the window and the
best guess stays. TV season discs aren't asked; their episodes are named from the
series instead.

If the right film isn't listed, type its name in the window's search box and press
Return to search again, or click **Use Typed Name** to name it exactly as typed. A
year at the end becomes `(Year)`: "Something's Gotta Give 2003" names it
`Something's Gotta Give (2003)`.

Some discs are labelled only `DVD_VIDEO`, `VIDEO_TS` or similar, which says nothing
about the film. Spindle doesn't look those up (it would only find unrelated
titles): the disc rips as `Untitled Disc <date time>` and the window opens with the
search box ready, so you can name it.

### Exact matches in Plex

When Spindle identifies a film, it files it with the film's IMDb id in the
folder and file names (the TMDB id if you use a TMDB key):

```
Movies/Army of Darkness (1993) {imdb-tt0106308}/
  Army of Darkness (1993) {imdb-tt0106308}.mkv
  Army of Darkness (1993) {imdb-tt0106308}.nfo
```

Plex reads the id and matches that exact film, instead of searching by title and
possibly picking another film with the same name. The `.nfo` file does the same
for Kodi, Jellyfin and Emby; Plex ignores it. A film you name by typing it in the
"Which film is this?" window has no id, so Plex searches for it as before.

If your library already has the film in a folder without the id (ripped by an
older Spindle), the folder and its files get the id when the next disc of that
film is filed, so the film stays in one folder.

### Several editions of one film

Rip the theatrical cut and the director's cut of a film and both land in the same
folder, one file per edition, named so Plex shows them as editions of one film:

```
Movies/Army of Darkness (1993)/
  Army of Darkness (1993) {edition-Theatrical Cut}.mkv
  Army of Darkness (1993) {edition-Director's Cut}.mkv
```

Spindle reads the edition from the disc label: `DIRECTORS_CUT` or a final `DC`,
`THEATRICAL`, `EXTENDED`, `UNRATED`, `UNCUT`, `ULTIMATE_CUT`, `FINAL_CUT`, `REDUX`,
`IMAX`, `SPECIAL_EDITION` and similar. If the film's first rip came from a disc
whose label named its edition, that file is tagged too when the second arrives;
otherwise it stays untagged, which Plex treats as the main version. A disc whose
label doesn't name its edition is filed as `Version 2` (then `Version 3`…); rename
the file's `{edition-…}` part to whatever you like. Re-ripping a disc replaces only
its own edition.

With **Sort rips into Movies / TV
Shows folders** on With **Sort rips into Movies / TV
Shows folders** on (Settings → Output & Routing), each finished rip is classified
by its title lengths:

- one long feature → **movie**, moved to the Movies folder;
- several titles of similar length → **TV season**, with each episode named and
  filed in the TV Shows folder (see [TV series](#tv-series));
- unclear → waits under **Review Rips**, pre-set to the app's guess, for you to
  confirm or switch. **Accept All Guesses** routes everything waiting.

Ripping never waits on a routing decision, and the review queue survives restarts.

Library folders can be on a NAS. Files are copied under a hidden name and renamed
once complete, so Plex never sees a partial file. Ripping a disc again replaces its
files in the same library folder instead of creating "Movie (Year) (2)"; anything
else you added to that folder stays.

## DVDs

DVDs need nothing beyond the app. Decryption uses libdvdcss.

- **Main movie by default.** Bonus features are ripped only if **Rip bonus features**
  is on.
- **All tracks.** Every audio and subtitle track is kept and labeled with its
  language from the disc.
- **Multi-version discs.** Some DVDs store several cuts of the movie in interleaved
  pieces ("seamless branching"). The app follows the disc's own navigation, as a
  DVD player does, so you get one clean copy of the movie, not every version back
  to back.
- **Scratched discs.** Unreadable sectors are retried one at a time, then skipped
  (up to a limit per title) so a small scratch doesn't fail the whole rip.
- **Interlaced video** (most NTSC DVDs) is deinterlaced automatically.

You can switch DVDs to MakeMKV with **Also use MakeMKV for DVDs**. It's usually
slower, because MakeMKV scans the entire disc before it starts.

## Blu-ray and MakeMKV

Blu-ray copy protection is handled by [MakeMKV](https://www.makemkv.com/), which
must be installed at `/Applications/MakeMKV.app`. Spindle runs it in the
background and names and files the results the same way as DVDs.

**When MakeMKV stops working:** its free beta builds expire. The app then shows a
dialog:

- **Download & Install** downloads the current MakeMKV from makemkv.com and
  replaces the old copy. Then click **Rip Now**.
- **Open Download Page** opens makemkv.com.
- **Enter Key…** registers MakeMKV with a key you have.

MakeMKV needs the drive to itself. Close MakeMKV's own window and DVD Player before
inserting a Blu-ray.

## TV series

A disc with several titles of about the same length is a TV season disc. Spindle:

1. **Picks the episodes**: every title of episode length, including a double-length
   pilot. The "play all" title (all the episodes joined) is skipped; extras such as
   featurettes are ripped only with bonus features on.
2. **Finds the show** from the disc label: `THE_OFFICE_S2_D3`, `SEINFELD_SEASON_3_DISC_1`
   and `FIREFLY_D1` all work. It looks the show up on [TMDB](https://www.themoviedb.org)
   if you've added a TMDB key, otherwise on OMDb.
3. **Numbers the episodes** in disc order. Disc 1 starts at episode 1; disc 2 starts
   after the last episode of disc 1, because Spindle remembers each show's discs.
4. **Files them** in the TV Shows folder as
   `Show (Year)/Season 01/Show (Year) - S01E05 - Title.mkv`. Extras go in
   `Show (Year)/Featurettes/`.

When Spindle isn't sure, nothing is renamed and the rip waits under **Review Rips**.
Hover over the disc name there to see why: the show wasn't found, disc 2 was
inserted before disc 1, or the label doesn't say which season of a multi-season
show it is. Choosing **TV Show** files the episodes with Spindle's best guess (season
1, continuing after the last disc it knows); choosing **Movie** moves the folder
unchanged.

**Add a TMDB key** for the best results: create a free account at themoviedb.org,
open Settings → API, and paste the API key (or the read access token) into
**TMDB API Key** in Settings → Output & Routing. TMDB lists episodes in the order the
discs use. OMDb, used without a key, lists them in broadcast order, which differs
for some shows (Firefly's DVDs start with "Serenity"; OMDb starts with "The Train
Job").

## Music CDs

Insert a music CD and Spindle:

1. **Identifies it** on [MusicBrainz](https://musicbrainz.org) from the CD's track
   layout (its disc ID): album, artist, year, track titles, and which disc of a set
   it is. If MusicBrainz doesn't know this exact pressing, a suggested match is used
   only when every track length agrees with the CD.
2. **Reads the tracks** to local storage (about 40 seconds a track) and ejects.
3. **Encodes each track to FLAC** in the background, tagged (title, artist, album,
   album artist, year, track and disc numbers, MusicBrainz IDs) with the front cover
   from the [Cover Art Archive](https://coverartarchive.org) embedded.
4. **Files it** in the Music folder (Settings → Output & Routing) as
   `Artist/Album (Year)/01 - Title.flac`, with `Disc 2/` folders for multi-disc sets
   and a `cover.jpg` in the album folder. Tracks by a guest artist are named
   `05 - Guest - Title.flac`.

A CD MusicBrainz doesn't know is ripped as `Unknown Artist/Unknown Album (…)/` with
tracks named `Track 01` and so on, so nothing is lost; you can rename it afterwards.
You can add the CD to MusicBrainz so it's recognized next time.

Video settings (codec, quality) don't affect CDs, so changing them doesn't re-rip
your CDs.

## Photo, home-video and data discs

**Photo discs.** A CD or DVD that's mostly photos (a burned camera card with a `DCIM`
folder, a Kodak Picture CD, a disc of JPEG, HEIC or RAW files):

1. The first time, Spindle asks where photos go: the **Photos folder**, **Apple
   Photos**, or **both**. Choose **Not Now** to leave the disc alone. You can change
   the answer in Settings → Output & Routing (**Photo Discs Go To**).
2. Every photo and camera clip is copied off the disc, and each copy is checked
   against the original. Other files (viewer programs, `autorun.inf`) are left on
   the disc. Then the disc ejects.
3. Photos are filed by the date they were taken (from the camera's EXIF data, or
   the file's date) as `Photos/2004/2004-07-14/IMG_0001.JPG`. Photos with no date go
   in `Photos/Undated/`. A different photo with the same name gets ` (2)`.

Spindle remembers each photo it has imported by its content, so the same photo on
another disc, or twice on one disc, is imported only once. Apple Photos asks for
permission the first time. If you don't allow it, the photos go to the Photos folder
instead, so nothing is lost.

**Home videos.** A video DVD on recordable media (DVD-R, DVD+R, DVD±RW, DVD-RAM),
the kind a camcorder or DVD recorder makes, is ripped into the Home Videos folder
instead of being looked up as a film. It's named by the date it was recorded (from
the label if it's a date, otherwise the disc's creation date) and its label:
`Home Videos/2004-07-14 Birthday Party/2004-07-14 Birthday Party.mkv`. Each recording
on the disc gets its own file, numbered ` - 01`, ` - 02`. A burned copy of a film is
treated as a home video too; move it if so.

**Other data discs** are copied as they are into
`Imported Discs/<disc name>/`, keeping their folders. Each file is checked against
the disc; any that can't be read (a scratched disc) are listed in
`Unreadable files.txt` in that folder. Inserting the same disc again updates its
folder; a different disc with the same name gets ` (2)`.

## Encoding

Choose the codec and quality in Settings → Encoding. The defaults (H.264, AAC, High)
play everywhere.

**Hardware acceleration** uses Apple's VideoToolbox for H.264 and HEVC. It's much
faster, at the cost of somewhat larger files. It needs a native Apple Silicon
FFmpeg: install one with `brew install ffmpeg`. If the app only has the
Intel FFmpeg it downloads itself, it encodes in software.

All encoding happens in `~/Library/Caches/Spindle/encoding/`. Only finished files
are moved to your output folder.

## Scripts

Settings → Advanced can run a script before each rip and another after it. See
[Settings Guide → Advanced](DETAILED_SETTINGS_GUIDE.md#advanced-tab) for what the
scripts receive.

## Troubleshooting

**A disc isn't detected.** In System Settings → Privacy & Security → Files and
Folders, make sure Spindle can access **Removable Volumes**. Quit DVD Player if
it opened on its own; it holds the drive.

**A disc was skipped.** It's already in the rip history. Hold **⌥ Option** while
inserting it, or click **Start Ripping**.

**Encoding fails right away.** Check the log for which FFmpeg was found. Install
Homebrew's (`brew install ffmpeg`) if the downloaded one won't run.

**A Blu-ray fails with a licensing message.** Use **Download & Install** in the
MakeMKV dialog.

**A Blu-ray fails with "Failed to open disc".** Something else is using the drive.
Close other disc apps and reinsert the disc.

**A TV disc ends up under Review Rips.** Hover over its name for the reason. Most
often disc 2 was inserted before disc 1 of that season, or the disc label doesn't
name the season. Choose TV Show to file it with a best guess.

**Photos didn't go to Apple Photos.** Spindle wasn't allowed to add to it. Allow
Spindle in System Settings → Privacy & Security → Photos; until then, photos are
filed in the Photos folder.

**A home DVD was looked up as a film, or a film went to Home Videos.** Spindle goes
by the disc type: recordable discs are home videos, pressed discs are films. Move
the files where they belong.

**A movie ends up under Review Rips.** The app couldn't tell from the title lengths
whether it's a movie or a TV season. Pick one there.

**A disc didn't eject, or a new disc wasn't noticed, while the Mac was locked.**
macOS doesn't allow discs to be mounted or ejected while the Mac is locked. A disc
that finishes reading then ejects as soon as you unlock; a disc inserted while
locked is pushed back out by macOS. To keep feeding discs without unlocking, turn
on **Keep this Mac awake and unlocked while Spindle is open** in the main window.
The Mac then stays unlocked, so use it where that's safe.

**A rip stopped when the Mac slept.** Older versions let the Mac sleep mid-rip; v2.1
prevents idle sleep while a job runs. Closing the lid still sleeps the Mac.

Still stuck? Open an issue at
https://github.com/gmoyle/Spindle/issues with your macOS version, the disc,
and the log.
