# ReadAloud

A personal, fully offline text-to-speech book reader for Windows and Android.
Open a PDF, EPUB, or TXT and have it read aloud — with a neural voice or the
system voices — with the current sentence highlighted, chapter navigation,
and your position remembered per book. No accounts, no telemetry, no network
use of any kind at runtime.

## Features

- **Library home screen** — every book you open is saved with its reading
  progress, chapter count, and position. Tap a card to resume exactly where
  you stopped. The bin icon removes a book (including its cache/position).
- **One-time extraction** — the first open parses the file (a moment for big
  books) and caches the result on disk; every later open is instant.
- **Chapters** — detected automatically from EPUB navigation, PDF bookmarks
  (outline), or "Chapter N"-style headings in the text. Open the drawer
  (☰, top-left of the reader) to jump between them.
- **Two voice engines** (voice picker: 🎙️ icon):
  - **Nathan (neural, British English)** — a bundled Piper voice model run
    through sherpa-onnx. Much more natural than system voices, identical on
    both platforms, exact-sentence highlighting everywhere. The very first
    play unpacks and loads the model (a few seconds; the play button shows a
    spinner) — after that it's instant.
  - **System voices** — whatever Windows/Android has installed. Spoken in
    paragraph-sized chunks for smoothness; on Android the highlight tracks
    the exact sentence (word-progress events), on Windows it tracks the
    speaking chunk.
- **Controls** — play/pause, ±sentence, ±paragraph, tap any sentence to jump
  there, speed slider (0.5x–2.0x), voice picker.
- **Resume** — the position is saved continuously per book (keyed by file
  name + size, so it survives moved files and Android's copied picker paths).

## Running it on Windows

The built app is self-contained in
`build\windows\x64\runner\Release\` — run `readaloud.exe` directly, or copy
that whole folder anywhere (e.g. `C:\Apps\ReadAloud\`) and make a shortcut.

To rebuild from source:

```
flutter build windows --release
```

(Requires Visual Studio 2022 with the "Desktop development with C++"
workload, and Windows Developer Mode turned on.)

## Building the APK and installing it on a Samsung phone

```
flutter build apk --release
```

The result is `build\app\outputs\flutter-apk\app-release.apk` (~120 MB — it
carries the neural voice model inside).

To sideload it:

1. Copy the APK to the phone — USB cable, or any local transfer you like.
2. On the phone, open the APK from **My Files**. Android will warn that
   installs from this source aren't allowed: tap **Settings** on that dialog
   and enable **Allow from this source** (this is the
   "Install unknown apps" permission for My Files — you can also find it
   under *Settings → Apps → ⋮ → Special access → Install unknown apps*).
3. Go back and tap **Install**.

Because this is a personal build, Play Protect may ask to scan the app —
that's fine, let it.

## Fully offline voices

The **Nathan** neural voice is bundled and needs nothing — it works offline
out of the box on both platforms. (Voice model: Piper
`en_GB-northern_english_male`, trained on the Crowdsourced UK English
corpus, OpenSLR-83, CC BY-SA 4.0.)

For the **system voices**:

- **Windows**: *Settings → Time & language → Speech*. The preinstalled
  voices (David/Zira/Hazel…) already work offline; add more under
  "Manage voices" → "Add voices" while online, then they work offline.
- **Samsung/Android**: *Settings → General management → Text-to-speech* →
  pick the engine (Samsung TTS or Google Speech services) → engine settings
  → **Install voice data** and download the voices you want while online.
  Downloaded voices work with no internet — flight-mode safe.

## Where things live

- Settings + library + positions: local app preferences (shared_preferences).
- Parsed book cache and the unpacked voice model: the app's support
  directory (Windows: `%APPDATA%\ReadAloud\readaloud`; Android: app data).
  Removing a book from the library cleans its cache and position.

## Publishing

See `PLAY_CHECKLIST.md` for the Google Play upload steps and `PRIVACY.md`
for the ready-to-host privacy policy.

## License

ReadAloud is free software, licensed under the
[GNU GPL v3](LICENSE). The speech pipeline bundles
[espeak-ng](https://github.com/espeak-ng/espeak-ng) (GPLv3) inside the
sherpa-onnx runtime, and the neural voice model
`en_GB-northern_english_male` is trained on the Crowdsourced UK English
corpus ([OpenSLR-83](https://openslr.org/83/)), CC BY-SA 4.0. Full component
credits are in the app under **About → View licenses**.

## Project layout (for tinkering)

- `lib/main.dart` — app + library home screen
- `lib/reader_screen.dart` — reader UI, highlighting, chapter drawer, controls
- `lib/tts_controller.dart` — playback state machine (chunking, resume, both engines)
- `lib/piper_engine.dart` — neural voice: model install, worker isolate, WAV playback
- `lib/text_extraction.dart` — PDF/EPUB/TXT extraction, cleaning, chapters
- `lib/book_cache.dart` — gzipped JSON cache of extracted books
- `lib/store.dart` — persistence (positions, settings, library)
- `test/extraction_test.dart` — extraction + chapter + cache tests (`flutter test`)
