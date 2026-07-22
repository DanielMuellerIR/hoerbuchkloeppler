**🌐 Sprache / Language:** [English](README.md) · [Deutsch](README.de.md)

<h1 align="center">Hörbuchklöppler</h1>

<p align="center">
  <strong>Turn a pile of loose audio files into a single, properly chaptered <code>.m4b</code> audiobook — with cover art, correct metadata, and remarkably small file sizes.</strong>
</p>

Hörbuchklöppler is a macOS tool that takes messy audio sources (`mp3`, `m4a`, `wav`, `flac`, or an existing `m4b`) and produces one clean `.m4b`: each input file becomes a chapter, cover art and tags are filled in, and the result is encoded with Apple's native AAC encoder. It ships in two forms on a shared core — a **SwiftUI app** and a **command-line tool `kloeppler`** for scripting and automation.

---

## 💡 The secret to small audiobooks (why the default is 32 kHz / 48 kbit/s mono)

Hörbuchklöppler defaults to **mono, 48 kbit/s, 32 kHz** — deliberately. That looks extreme if you are used to music bitrates, but for **spoken word** it is the sweet spot:

- For plain narration, the difference to a high-bitrate encode is **practically inaudible**.
- The files become **tiny** — a multi-hour book shrinks to a fraction of the usual size, which matters on phones, in the cloud, and for whole libraries.

This is the tool's core idea, not an accident. Speech simply does not carry the high-frequency, wide-stereo content that would justify a large file. If you are unsure, **listen for yourself**:

```bash
# Take any public-domain narration (e.g. a LibriVox chapter, which is public domain)
# and encode it with the default settings — then compare it to the original:
kloeppler /path/to/folder-with-one-chapter --mono --bitrate 48k --samplerate 32000
```

> A ready-made A/B sample accompanies the releases: the same 49-second recording at 128 kbit/s (772 KB) vs. the Hörbuchklöppler default (299 KB — about **61 % smaller**). Play both — for narration the difference is barely audible. Source: *"Wunder über Wunder"* from [Sammlung deutscher Gedichte 018](https://archive.org/details/sammlung_deutscher_gedichte_018_1506_librivox) ([LibriVox](https://librivox.org/) — public domain).

You can of course raise the bitrate/sample rate (`--bitrate`, `--samplerate`, `--stereo`) for music or dramatized recordings.

---

## Features

- **Any input → one `.m4b`:** `mp3`, `m4a`, `wav`, `flac`, and existing `m4b` (chapters are re-extracted).
- **Chapters:** one input file = one chapter; existing `m4b` chapter structure is read back in and stays editable.
- **Cover art:** embedded artwork first, otherwise the largest image in the folder (`folder.jpg`), or drop your own.
- **Metadata:** title, author and genre are read via MediaInfo and can be overridden.
- **Auto-split:** optionally split long books into `-01`, `-02` … at a maximum duration (1–24 h).
- **Two encoding modes** (see below): a safe sequential mode and a fast parallel mode.
- **Scriptable:** the `kloeppler` CLI exposes every option as a flag, with honest exit codes.

---

## Install / Build

> **No ready-made download / Releases DMG — on purpose.** Unlike some other
> projects, this repository does **not** offer a prebuilt `.app` or `.dmg` under
> Releases. A bundled build would contain `ffmpeg`, which is licensed under the
> **GPL**; distributing it would pull the corresponding GPL obligations (shipping
> its source or a written offer) onto this project. To keep this project clear of
> those obligations, `ffmpeg`/`mediainfo` are fetched from their official upstream
> **at build time** instead. That means there is no one-click download — but
> building is a single command.

Requires macOS (Apple Silicon or Intel) and Xcode command-line tools.

```bash
git clone https://github.com/DanielMuellerIR/hoerbuchkloeppler.git
cd hoerbuchkloeppler
./build.sh
```

`build.sh` downloads the external tools `ffmpeg` and `mediainfo` from their official upstream (they are **not** shipped in this repository — see [Dependencies](#dependencies)), builds the core, the CLI and the app, and places `Hörbuchklöppler.app` in the project root for easy testing.

```bash
./build.sh --cli-only   # only the command-line tool
./build.sh --help       # all options
```

### Install to /Applications (optional, signed & notarized)

`build.sh` produces a quick, ad-hoc-signed **development build** in the project root — handy for testing the current state. If you want the app permanently in `/Applications` as a **deliberately installed, notarized version** — signed with a Developer ID and notarized by Apple, so it launches without Gatekeeper prompts (also on other Macs) — use `install.sh`:

```bash
./install.sh                 # build → sign → notarize → staple → /Applications
./install.sh --no-notarize   # Developer-ID-signed test build in the project; never installs
./install.sh --help
```

This needs an Apple **Developer ID Application** certificate in your keychain and a `notarytool` keychain profile. The profile name comes from the `NOTARY_PROFILE` environment variable or a clone-local git config — it is never committed, and credentials stay in the keychain (never passed on the command line). `--no-notarize` still needs the Developer ID but exits after verifying the project-local test build; only a successfully notarized, stapled and Gatekeeper-accepted build may be copied to `/Applications`. Without a Developer ID, use `./build.sh`.

Building locally and installing to your own `/Applications` is **not** redistribution, so it stays clear of the GPL obligations that the bundled `ffmpeg` would otherwise pull in (see [Install / Build](#install--build) above).

---

## Command-line usage (`kloeppler`)

The CLI is a first-class way to use Hörbuchklöppler — ideal for scripts and AI agents.

```
kloeppler <folder> [--mode parallel|standard] [--bitrate 48k] \
          [--samplerate 32000] [--max-duration 0] [--mono|--stereo] \
          [--title <title>] [--author <author>] [--output <target>] \
          [--verbose] [--force]
```

- `<folder>` — a folder of audio files (one file = one chapter). Cover = largest image / `folder.jpg`.
- `--title` / `--author` override the tags detected from the files (`--title` also names the output file).
- `--output` — a target folder or a full `.m4b` path. Without it the file lands next to the source.
- `--max-duration <hours>` — split long books (`0` = unlimited).
- **Exit codes:** `0` only on real success, `≠ 0` otherwise (SIGINT / Ctrl-C returns `130`) — safe for automation.
- Inputs are validated up front (mode, bitrate, sample rate), so mistakes fail fast with a clear message.

---

## How it works

Two encoding strategies, switchable per run:

- **Standard (safe):** slice every chapter to uncompressed `.wav`, then do a **single** AAC encode straight into the final `.m4b`. No stream-copy of pre-encoded segments — best for continuous music across chapter boundaries.
- **Performance (fast):** encode every chapter to AAC in parallel, then stream-copy-merge them without re-encoding. Faster, and for spoken word the boundaries stay clean (chapters begin and end in silence). See [docs/encoding.md](docs/encoding.md).

Both use Apple's `aac_at` (AudioToolbox) encoder in Constrained-VBR mode for quality above ffmpeg's native AAC.

**Which to pick — trade-offs:**

| | Performance (default) | Standard |
|---|---|---|
| **Speed** | Fastest | Slower |
| **CPU** | Uses all cores — fans will spin up | Gentler (a single final encode) |
| **Temp disk** | Small (only the compressed segments) | **Large** — writes uncompressed `.wav` for *all* chapters at once; merging several long books can mean **many GB** of temporary files until the run finishes |
| **Best for** | Most audiobooks; limited disk space | Gapless music; when you'd rather keep CPU load low |

If you want the machine to stay quiet and responsive, use Standard — but make sure you have enough free disk space for the temporary WAVs. If disk space is tight, use Performance.

---

## Dependencies

- [Swift Argument Parser](https://github.com/apple/swift-argument-parser) (fetched by SwiftPM).
- **`ffmpeg`** and **`mediainfo`** at runtime — downloaded by `build.sh`, not committed to this repo. `ffmpeg` is licensed under the **GPL**; it is used here as a separate, unmodified subprocess (not linked in) and is fetched by the user from the official upstream, so it is not redistributed by this project. Details: [docs/dependencies.md](docs/dependencies.md).

For a deeper map of the code, see [AGENTS.md](AGENTS.md) and the [`docs/`](docs/) folder.

---

## License

This project's own code is licensed under the [MIT License](LICENSE). The external `ffmpeg`/`mediainfo` binaries keep their respective upstream licenses (GPL-3.0 / BSD-2-Clause) — see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) for the full third-party license details.
