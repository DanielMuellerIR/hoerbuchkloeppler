[English](README.md) · [Deutsch](README.de.md)

# Hörbuchklöppler

Hörbuchklöppler turns audio files into a chaptered `.m4b` audiobook with
cover art and metadata. The macOS app and the `kloeppler` command-line tool
share the same import and encoding code. Both accept MP3, M4A, WAV, FLAC,
and existing M4B files.

## Audio quality and file size

The default for narration is mono AAC at 48 kbit/s and 32 kHz. The
49-second release sample is 299 KB at these settings and 772 KB at
128 kbit/s, a reduction of about 61%. The recording is *Wunder über
Wunder* from LibriVox's [Sammlung deutscher Gedichte 018](https://archive.org/details/sammlung_deutscher_gedichte_018_1506_librivox).

For music or dramatized recordings, you can increase the bitrate and
sample rate and use stereo.

## Edit chapters and save a project

Import a folder or drop audio files into the app. Each file becomes a
chapter by default, and existing chapter markers in M4B files are preserved
as editable chapters. Edit titles, reorder chapters by dragging them, or
select a group and number it with a common prefix.

To split a chapter, play it from the chapter list and click **Teilen**
(Split) at the desired position. **Zusammenführen** (Merge) joins the
selected chapter to the next one when their ranges are adjacent in the
same source file. Save your work with Cmd+S as a `.hkproject`. The project
references the source audio and stores the chapter edits, metadata, cover,
and conversion settings. You can reopen it or pass it to the CLI.
[Projects and chapter editing](docs/projects.md)

The app reads artwork and tags from the source files. You can choose your
own cover and edit the book metadata. Review the planned files in the
output preview before encoding. The audio settings offer optional
loudness analysis and a single gain adjustment for the whole book, aiming
for −18 LUFS within the peak limit. A maximum duration can split long
books into files numbered `-01`, `-02`, and so on.
[Encoding and loudness](docs/encoding.md)

## Install or build

The app build requires macOS (Apple Silicon or Intel) and Xcode. The
CLI-only build uses the Swift toolchain from the Xcode command-line tools.
Build locally. The repository distributes source code, and `build.sh`
fetches `ffmpeg` and `mediainfo` from their upstream projects. The
resulting bundle contains GPL-licensed `ffmpeg`.
[Dependencies and licenses](docs/dependencies.md)

```bash
git clone https://github.com/DanielMuellerIR/hoerbuchkloeppler.git
cd hoerbuchkloeppler
./build.sh              # ad-hoc-signed app in the project root, plus the CLI
./build.sh --cli-only   # build only the command-line tool
./build.sh --help
```

### Install a notarized build

`install.sh` requires a Developer ID Application certificate and a
`notarytool` keychain profile. Set the profile name with `NOTARY_PROFILE`
or the clone's local Git setting `hoerbuchkloeppler.notaryProfile`.
Use `build.sh` for ad-hoc signing.

```bash
./install.sh                 # build, notarize, staple, verify and install in /Applications
./install.sh --no-notarize   # Developer-ID-signed test build in the project
./install.sh --no-install    # notarized app in the project
./install.sh --help
```

### Create a disk image for another Mac you own

`release.sh` uses the same certificate and profile. It packages the
notarized app in a separately notarized DMG for use on your own Macs.

```bash
./release.sh                     # dist/Hörbuchklöppler-<version>.dmg
./release.sh --no-finder-layout  # skip Finder window layout
```

## Command-line usage

From the project root, make the locally built CLI available in your shell.

```bash
export PATH="$PWD/HoerbuchkloepplerCore/.build/release:$PATH"
kloeppler --help
```

Choose a folder, a saved project, or an ordered list of audio files for
each run.

```bash
kloeppler "/path/to/chapters" --title "My book" --output "My book.m4b"
kloeppler --project "My book.hkproject" --inspect --format json
kloeppler --file 02.wav --file 01.wav --normalize-loudness --output "My book.m4b"
```

- Use `--project` for a saved project and repeat `--file` for each audio
  file in the desired order. `--inspect` analyzes the sources and previews
  the output paths without creating files. Use `--format json` for a JSON
  inspection report or line-delimited JSON conversion events.
- Set audio with `--mode`, `--bitrate`, `--samplerate`, `--mono`, or
  `--stereo`. Use `--workers` to limit encoding processes and
  `--import-workers` to limit concurrent source analysis.
- Use `--analyze-loudness` to measure the book's loudness or
  `--normalize-loudness` to measure it and apply a common gain.
- Override tags with `--title`, `--author`, `--genre`, `--narrator`,
  `--series`, `--volume-number`, and `--language`. Choose artwork with
  `--cover` or omit it with `--no-cover`.
- Use `--max-duration` to split by length and `--output` to set a
  destination folder or full `.m4b` path. The default output directory
  is the source's parent directory. `--verbose` adds diagnostic detail.
  `--force` allows overwriting an existing output in scripts.

Exit status is `0` on success, `64` for invalid arguments, `130` for an
accepted Ctrl-C interruption, and `143` for an accepted SIGTERM.
[CLI reference and verification](docs/build-and-test.md#cli-kloeppler)

## Encoding modes

- **Performance (default)** encodes chapters in parallel and joins the AAC
  segments without re-encoding. It uses less temporary space. Priming and
  padding on each segment can shift audio transitions near chapter marks.
- **Standard** prepares WAV files, then encodes the book in one AAC pass.
  Use it for continuous music across chapter boundaries. The WAV files can
  take several GB for long books.

Both modes use Apple's AudioToolbox AAC encoder with constrained variable
bitrate. Optional loudness analysis uses temporary WAV files in either mode.
[Encoding details](docs/encoding.md)

## Development and licenses

[Architecture](docs/architecture.md) · [Building and testing](docs/build-and-test.md) · [Dependencies](docs/dependencies.md)

The app and CLI are available under the [MIT License](LICENSE).
Swift Argument Parser is fetched by SwiftPM. The `ffmpeg` and `mediainfo`
binaries retain their upstream licenses (GPL-3.0 and BSD-2-Clause).
[Third-party notices](THIRD-PARTY-NOTICES.md)
