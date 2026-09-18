# On-device downloads

Implementation prepared for the `HasanGs27-patch-1` IPA. Compilation and device acceptance are required before release.

## User flow

- Enable **Player → Flèche : téléchargements locaux** (enabled when the preference has never been set).
- The supported playlist download control starts preparation without opening another page. Tap it again for progress, pause/resume, or the downloaded selection.
- **Player → Téléchargements automatiques** also accepts a Spotify track or playlist link. The default mode is **Cet iPhone · autonome**; the paired PC remains an optional mode.
- Green means a verified local file is available. Red means a failed item can be retried or supplied with a file, direct HTTPS MP3/M4A link, or matching YouTube / YouTube Music video link.
- Amber on a playlist means the accessible tracks are saved but the completeness of the playlist has not been established.
- Keep Spotify open during preparation. If iOS ends its background allowance, the transfer pauses and completed files are kept. Resume is explicit after reopening.

## Source and quality

The phone matches public YouTube Music song metadata against title, artist, and duration, resolves an AAC/M4A audio stream locally, then validates and stores the received file. It does not re-encode the audio. No account cookies or external extraction server are used. A failed or ambiguous match requires another source; catalogue coverage and source availability are not guaranteed.

Spotify public embed metadata can be incomplete. When the native download manager supplies a real list of track URLs, that ordered list is used. Otherwise the selection is explicitly marked potentially incomplete; private playlists may need individual links or files. Duplicate entries retain their original positions.

The installer checks the audio container, readable compressed packets, duration, embedded metadata, and file hash. It adds title/artist/cover metadata when possible. Files are stored under `Documents/Spoti Downloads`, with a durable index and queue. Pending or invalid files do not turn green.

When offline status is known, compatible native play requests can use verified copies belonging to the requested selection. Online play requests keep Spotify's existing path. Unknown native context shapes pass through. The existing artwork, lock-screen, and player patches are separate and unchanged by this feature.

## Validation

`scripts/test-native-audio.sh` compiles the standalone Swift resolver and runs deterministic parser/matching tests on macOS. `--live` additionally resolves a source and checks M4A bytes; a network failure is reported separately and is not download success.

The IPA workflow also runs collection metadata, durable model, local manifest, and synthetic audio import tests before compiling the tweak. `NativeAudioVendorPin.txt` records dependency revisions and hashes; `NativeAudioLicenses.txt` is copied into the delivered app.

Device acceptance still needs a real download-button tap, pause/resume, a failed-source repair, airplane-mode playback, and an online playback/Canvas regression check. Diagnostics are limited to the relevant playlist/button and playback path in `Caches/spoti-download-diagnostics.json` and `Caches/spoti-offline-playback.json`.
