# Google Play upload checklist

The code side is done: neutral application ID, release signing, adaptive
icons, no personal data in the project, no permissions, no network use.
What remains is Play Console work — none of it is code.

## Already done in the project

- **Application ID**: `app.readaloud.reader` (in
  `android/app/build.gradle.kts`). ⚠️ You may change it, but ONLY before
  the first upload — after that it is permanent forever. It contains no
  personal information.
- **Release signing**: `android/upload-keystore.jks` +
  `android/key.properties` (both git-ignored).
  ⚠️ **BACK BOTH FILES UP somewhere safe** (password manager + offline
  copy). With Play App Signing an upload key can be reset via Google
  support, but it's slow and painful.
- **Icons**: adaptive launcher icons generated from `assets/icon/`.
- **Bundled voice**: Piper `northern_english_male` (dataset OpenSLR-83,
  **CC BY-SA 4.0** — redistribution is allowed WITH attribution; see
  "Store listing" below). The previous Alan voice was removed because its
  dataset is "All Rights Reserved" (not redistributable).
- **The upload artifact**: `flutter build appbundle --release` →
  `build/app/outputs/bundle/release/app-release.aab`. Play requires the
  .aab (not the .apk); it also serves each phone only its own CPU
  architecture, which keeps the download smaller than the universal APK.

## Play Console steps (you)

1. **Developer account**: play.google.com/console — one-time $25 fee.
   Note: Google requires developer identity verification, and for personal
   accounts your developer name (and since 2024, for some account types a
   contact address) appears on the listing. Decide what you're comfortable
   showing; a neutral developer name is allowed for personal accounts.
2. **Create app** → fill in name "ReadAloud", default language, App, Free.
3. **Privacy policy**: use this public URL (the policy is hosted in the
   app's GitHub repo):
   `https://github.com/ooga-og/readaloud/blob/main/PRIVACY.md`
4. **Data safety form**: declare — collects no data, shares no data, no
   security practices needed (nothing leaves the device). This matches the
   app: it has no INTERNET permission at all.
5. **Content rating questionnaire**: it's a utility/reader with only
   user-provided content → rated Everyone.
6. **Store listing assets** you must make:
   - 512×512 icon: use `assets/icon/icon.png` scaled down.
   - Feature graphic 1024×500.
   - At least 2 phone screenshots (run the app, screenshot library +
     reader).
   - Short + full description. Include this attribution line in the full
     description (required by the voice's CC BY-SA 4.0 license):
     "Neural voice: Piper 'northern_english_male', trained on the Crowdsourced
     UK English corpus (OpenSLR-83), CC BY-SA 4.0."
7. **Upload**: Production (or start with Internal testing) → upload
   `app-release.aab` → accept Play App Signing → roll out.

## Licensing notes (worth 2 minutes)

- **Syncfusion PDF library**: free under the Syncfusion Community License
  (individuals / companies under $1M revenue, ≤5 developers). Register for
  the free community license at syncfusion.com to be covered when
  publishing. If you'd rather avoid it, say the word and the PDF engine can
  be swapped for a fully-open alternative.
- sherpa-onnx: Apache 2.0 ✓. Piper: MIT ✓. Flutter & plugins: BSD/MIT ✓.

## Version bumps for updates

Edit `version:` in `pubspec.yaml` (e.g. `1.0.1+2` — the number after `+` is
the versionCode and must increase on every upload), rebuild the .aab,
upload.
