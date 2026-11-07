# How Aria works

Roughly 3,500 lines of Swift, no dependencies. This document covers the parts that are
non-obvious or easy to get wrong.

---

## Reading FLAC metadata

`AVFoundation` decodes FLAC audio on both platforms, but it will not give you Vorbis
comments — so `Models/FLACMetadata.swift` parses the container directly.

A FLAC file is the magic `fLaC`, then a chain of metadata blocks, then audio frames. Each
block header is four bytes: a last-block flag in the top bit, a 7-bit type, and a 24-bit
big-endian length. Aria reads three block types:

- **STREAMINFO** (type 0) packs sample rate, channel count, bit depth and total sample count
  into 64 big-endian bits starting at byte 10. Duration comes from here, so it's exact and
  costs no decoding.
- **VORBIS_COMMENT** (type 4) is the one block that uses **little-endian** lengths. Getting
  this wrong yields garbage.
- **PICTURE** (type 6) holds the cover. Aria records only the *byte range* during a scan and
  reads the image later on demand — scanning a library touches a few KB per file rather than
  megabytes of JPEG.

A repeated key (several `ARTIST` lines) is joined with commas for display, but only the
**first** value is kept for grouping. Otherwise a track credited to "Lead, Feature" files
itself under a different artist than the rest of the album.

## Reading everything else

`Models/AudioMetadata.swift` dispatches on the container: FLAC goes to the hand-written
parser above, and MP3, M4A, WAV, AIFF and CAF go to AVFoundation. Two things drove that
split.

**Vorbis comments are still FLAC-only.** AVFoundation exposes FLAC's tags as metadata
items, but the hand-written reader is cheaper and gives the exact bit depth, which the
system reports as 0 for every compressed stream.

**The extension lies about the codec.** An `.m4a` is either ALAC or AAC, and only one of
them is lossless. The format therefore comes from the *media subtype* of the file's first
audio track (`kAudioFormatAppleLossless` vs `kAudioFormatMPEG4AAC`), not from its name.
ALAC also needs one extra step: its word length lives in the magic cookie, inside the
`alac` box, thirteen bytes past the box type — the stream description reports 0 there too.

Tags are mapped onto the same `TITLE` / `ARTIST` / `ALBUMARTIST` / … dictionary the Vorbis
reader produces, so `Track` has no per-container branching. The mapping keys off
`AVMetadataItem.identifier` (`id3/TPE2`, `itsk/aART`) because iTunes atom keys come back as
integers, and falls back to `commonKey` for containers with no identifier mapping. Two
details are easy to get wrong: `trkn` and `disk` are big-endian byte pairs rather than
text, and ID3's `TDAT` (day/month) maps to the same `commonKeyCreationDate` as `TDRC`, so a
year is only accepted when it reads as 1900–2100.

Cover art is located differently per container. FLAC records the picture's byte range
during the scan and reads only those bytes later. The other containers hand the picture to
`AVMetadataItem.dataValue`, which is loaded once per album, on demand, rather than during
the scan — a 500-track MP3 library would otherwise pull hundreds of megabytes of JPEG
through memory just to fill a grid.

## Scanning

`LibraryStore` walks the tree, then parses headers concurrently with a `TaskGroup`. Results
are cached to `Application Support/Aria/library.json` so the next launch shows the library
instantly while a fresh scan reconciles with disk.

`dateAdded` is carried across rescans, so "Recent" doesn't reshuffle every time you scan.

## The audio graph

```
AVAudioPlayerNode ──▶ AVAudioUnitEQ ──▶ mainMixerNode
```

Two details matter:

**The player node's clock resets on every reschedule.** Seeking therefore tracks a separate
`seekFrame` offset, and the current time is `seekFrame + playerTime.sampleTime`.

**Completion callbacks fire on `stop()` too.** A seek stops the node, which triggers the
outgoing segment's `.dataPlayedBack` callback — indistinguishable from the track genuinely
ending. A generation counter, bumped on every schedule, lets stale callbacks be ignored.

**Sample-rate changes rebuild the graph.** When a file's format differs from the current
connection, the graph is reconnected — and it has **two** hops now that the equalizer sits
in the chain. Reconnecting only the first silently drops the EQ out of the signal path.

On iOS the audio session is configured `.playback` (without it the ringer switch mutes the
app and playback dies on lock), and the hardware is asked to run at the file's own sample
rate so 44.1 kHz material isn't resampled to iOS's default 48 kHz.

## Colour extraction

`Library/ArtworkPalette.swift` draws the cover into a 28×28 `CGContext` and walks the raw
bytes. Pixels are bucketed by hue and weighted by saturation, so a mostly-grey sleeve with
one vivid element themes from that element rather than averaging into mud. Near-black,
near-white and near-grey pixels are skipped.

The result is a hue and a chroma. `Views/Theme.swift` turns that into a Material-style set
of colour roles — surfaces, primaries, foregrounds. Real Material 3 derives tones in the HCT
colour space; this approximates the same idea in HSB, which is visually close and needs no
colour-science dependency.

Two things learned the hard way:

- **Surfaces need a brightness floor.** At 14% brightness every tint collapses to
  near-black and the whole dynamic-colour effect disappears. Dark surfaces sit near 19%.
- **Chroma needs a floor too**, or muted artwork produces a grey interface. Genuinely
  greyscale art (chroma below 0.03) still yields grey, which is correct.

Three surfaces theme independently: the library keeps its own hue, the mini-player and Now
Playing take the current track's, and opening an album re-tints the window from its cover.

## The equalizer

Ten `AVAudioUnitEQ` parametric bands on Winamp's original centre frequencies — 70, 180, 320,
600, 1k, 3k, 6k, 12k, 14k, 16k Hz. Using Winamp's own band centres rather than the ISO set
means its 18 presets apply exactly as designed, with no resampling of a curve built for
different frequencies.

Preset values were converted from Winamp's 0–63 storage (33 = unity, ±20 dB span) to
decibels, and `Player/Equalizer.swift` was generated from that data rather than transcribed.

Switching the equalizer off sets `bypass` on every band rather than zeroing the gains, so
there is no processing cost when it isn't in use.

## Playlists

Membership can't be stored as an absolute path — that changes between machines — so each
entry keeps three identifiers and resolution tries them in order:

1. **Relative path** below the library root. Reliable when the layout matches.
2. **Title + album** from the file's own tags. This is what rescues a playlist moved to a
   phone: copying to iOS rewrites any non-ASCII character in a filename, so
   `hell's middle child.flac` arrives as `hell?s middle child.flac`, while the tags inside
   the file are untouched.
3. **Filename**, as a last resort.

Paths are normalised by stripping a leading `/private` before comparison. `/tmp` and `/var`
are both symlinks, so a root recorded as `/var/mobile/…` and a file reported as
`/private/var/mobile/…` name the same place while sharing no prefix — without normalising,
the relative path is silently lost and everything falls back to filename matching.

`importFolders` builds one playlist per top-level folder, which turns an existing
folder-per-genre layout into something playable in a single click.

## De-duplication

Tracks are collapsed when title, artist, album and rounded duration all match — narrow
enough to keep two different songs that share a title, broad enough to catch a re-download.
Where a name ends in `_01`, `_02` and so on, that copy is the one dropped.

## Platform abstraction

`Platform/Platform.swift` is the whole of it: a `PlatformImage` typealias, an
`Image(platformImage:)` initialiser, and shims for the pasteboard, reveal-in-Finder and
folder picking. Everything else is shared.

Consequences worth knowing:

- Colour extraction uses `CGContext` rather than `NSBitmapImageRep`, which is macOS-only.
- `homeDirectoryForCurrentUser` is unavailable on iOS; `NSHomeDirectory()` works on both.
- The library root is `~/Music` on macOS and the app's Documents folder on iOS.
- `Views/iOS/PhoneRootView.swift` holds the phone layout — floating nav bar, mini-player
  pill, full-screen Now Playing. The rest of the views are shared and adapt via
  `screenInset` and a few `#if os(iOS)` branches.

## System integration

`NowPlayingController` bridges to `MPRemoteCommandCenter` and `MPNowPlayingInfoCenter`.

One trap: **registering the skip commands hides the track buttons.** If
`skipForwardCommand` / `skipBackwardCommand` are registered, iOS shows 15-second skip
buttons on the lock screen, in Control Center and on AirPods *instead of* next/previous. You
can't have both — the system prefers the skip pair. Aria disables them explicitly.

## The mascot

`Views/MascotScrubber.swift`. He's the progress control: a rail with a character standing on
it at the playhead, draggable to seek. He bounces about twice a second, tilts into the beat,
swings his arms, alternates his legs, squashes on landing, blinks, and sings along. Paused,
he shuts his eyes and a `z` floats up.

Two constraints shape the drawing:

- **Limbs are drawn outside the head's outline.** Body and limbs share one fill colour, so
  anything overlapping the head simply vanishes.
- **The floating notes live in an `.overlay`, not the `ZStack`.** As children their reach
  inflated the bounds, and `.frame` then re-centred the whole character — lifting him off
  the rail he's meant to stand on.

Below 26 points the headphones and arms turn to mush, so the mini-player gets a simplified
version.

## Testing without a screen

There's no test suite yet, but two techniques carried this project:

**Render SwiftUI offscreen.** Compile the view sources into a small CLI, host them in an
`NSHostingView` inside an off-screen `NSWindow`, then `cacheDisplay` into a bitmap and write
a PNG. This catches real layout bugs. Note that `ImageRenderer` is *not* suitable — it
silently renders `ScrollView` content and `TextField` as blank.

**Drive the real types headlessly.** Compiling the model and player sources into a CLI lets
you assert on actual playback: that the clock advances, that a seek lands where asked, that
preset gains reach the live audio unit.

Neither technique catches gesture bugs. A row that needed a double tap on a touchscreen
looked perfect in every screenshot.
