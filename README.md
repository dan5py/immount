# Immount

Immich in your Finder. Immount mounts your [Immich](https://immich.app) library as a folder in the Finder sidebar, like iCloud Drive: browse albums, favorites, people, tags and your timeline, Quick Look photos, and drag originals into any app. Files download only when you open them.

```
Immich/
├── Albums/<album>/
├── Favorites/
├── People/<person>/
├── Tags/<tag>/<nested tag>/
└── Timeline/<year>/<MM Month>/
```

Immount is read-only for now: it never changes anything on your server.

Tags preserve the hierarchy from Immich. Each tag folder contains its child tags and matching photos and videos, including assets tagged with a child tag. Tagged archived assets are included; hidden, locked, trashed, and offline assets are excluded.

At home, Immount can talk to the server directly. Set a local URL (e.g. `http://192.168.1.10:2283`) and the Wi-Fi networks where it is reachable, and Immount switches between the local and the public address as you move, like Home Assistant's internal URL. macOS only reveals the Wi-Fi name to apps allowed to use Location Services, so Immount asks for that permission.

## Requirements

- macOS 14.0 or later
- An Immich server. Tested with 3.2. Older servers (2.x, 3.0, 3.1) get the older search API automatically, but are untested.
- An API key with these permissions, or `all`:

  | Permission       | Used for                                   |
  | ---------------- | ------------------------------------------ |
  | `asset.read`     | Listing photos and videos                  |
  | `asset.view`     | Thumbnails in Finder                       |
  | `asset.download` | Downloading originals when you open a file |
  | `album.read`     | Albums                                     |
  | `person.read`    | People                                     |
  | `tag.read`       | Tags and their hierarchy                   |
  | `user.read`      | Checking which account the key belongs to  |

  Immount checks the key with `GET /api/api-keys/me` when you connect and tells you which permissions are missing.

## Settings and privacy

- The server address and local network settings are stored in the app group's preferences. The API key is stored in the Keychain. Immount never stores or shows your Immich name or email.
- **Disconnect** removes Immich from Finder but keeps the server and key, so connecting again is one click. **Forget Server…** erases everything from the Mac.
- Away from home, Immount only uses the server URL. The Finder extension can't see the Wi-Fi network, so the app tells it when the local URL is safe to use, and that permission expires within minutes if the app quits, crashes or the Mac sleeps. It never falls back to the local address otherwise, because that private IP could belong to another device on someone else's network.
- Requests keep nothing on disk and don't follow redirects to other hosts, so the API key only goes to the server you entered.
- Update checks only download the release feed from GitHub. Immount sends no system profile or usage data with them.

## Background running, cache, and statistics

In General, both **Menu bar icon** and **Dock icon** can be turned off. Closing the window keeps Immount running, renewing the local-network connection and refreshing Finder. Open Immount from Finder or Spotlight to return to Settings. Turn on **Launch at login** to start it automatically; quit from the app menu or with Command-Q when its window is active.

Immich is in Finder only while Immount runs. Quitting removes the Finder location, which also stops the File Provider extension, and deletes downloaded originals; the connection, API key and saved folder listings stay, so the next launch shows the library again right away. If Immount ends without quitting (force quit, a crash, or stopping a debug session in Xcode), the extension notices within a few seconds, removes the location itself and exits.

General's **Cache** section shows the number and estimated size of originals still downloaded on this Mac, independently of whether statistics are enabled. **Clear Cache…** asks macOS to remove those local copies; opening a file downloads it again. The server library, saved connection, library index, and statistics totals are preserved. Files that are open, have local changes, or are kept downloaded can remain; Immount reports partial cleanup and checks the size again. The estimate sums file sizes, so it can differ from the disk space recovered, and excludes system-managed thumbnails. While General is open, usage is checked when the pane appears, shortly after Immount finishes downloading originals (at most once a minute, and only while statistics are enabled), and otherwise every five minutes; the refresh button beside Clear Cache checks right away.

The **Enable statistics** switch at the top of the Statistics pane controls collection on this Mac. It is on by default. Turning it off stops statistics requests and download measurements, including measurements for downloads already in progress. Existing totals are kept; turning it back on measures new downloads. Your Finder connection and regular library refreshes continue.

When enabled, the **Statistics** pane shows:

- HTTP response time for the selected server address.
- Actual Finder download speed, a one-minute activity graph, completed download totals, and the last download's average speed. Only original files downloaded through Immount count; thumbnails and files already cached by macOS do not. Totals are local to this Mac and the connected server, count only downloads made while statistics are enabled, and reset when you disconnect.
- Photo and video counts for your timeline and archive, excluding hidden items and trash.
- Server disk usage, including other data on the same disk.

Library counts require the optional `asset.statistics` API key permission, and server storage requires `server.storage`. These are described in the [Immich API documentation](https://api.immich.app/); neither is required to connect Finder. If a permission or endpoint is unavailable, its section explains why. Download measurements remain available. Server statistics refresh every 30 seconds while the pane is open; download activity updates every second. Saved download measurements contain no filenames, asset IDs, addresses or API keys.

## Updates

Immount updates itself with [Sparkle](https://sparkle-project.org). It checks once a day; **Check for Updates…** is in the app menu, the menu bar menu and Settings > About, where you can also turn off automatic checks or let updates download and install on their own. Because Immount mostly runs in the background, an update found by a scheduled check doesn't open a window over your work: the menu bar menu shows **Update to x.y Available…** until you look at it. Every update is verified with an EdDSA signature before it installs.

## How it works

While connected, Immount normally checks folder metadata about every **30 seconds**. Changed albums and timeline months, along with recently browsed folders, get priority. Unchanged responses reuse a bounded in-memory ETag cache, and concurrent refresh requests share one scan. Unchanged listings are not rewritten to disk.

Between those checks, Immount looks at the album list alone every **10 seconds** (usually a small "not modified" answer). When an album is added, removed, renamed or gains or loses photos, it asks for a check right away, so an album you are browsing updates within seconds of the change in Immich. This quick look runs only on mains power, on an unrestricted network, outside Low Power Mode, and while the Mac has been used in the last five minutes; otherwise the regular schedule applies alone. It pauses after a failed request until a regular check succeeds.

Folders without a useful change signal, such as Favorites or tag membership, also receive rotating background checks after five minutes and a safety check after ten minutes. **Refresh Now** immediately requests a check of every previously browsed folder. Newly opening a folder fetches its current contents. Finder shows folders it has listed before from its own copy, but it tells the extension each time it shows one (a new window, Back, the path bar), so Immount then checks that folder about a second later, at most once every 15 seconds per folder; Finder updates the window if anything changed.

Automatic checks slow to 60 seconds in Low Power Mode or 120 seconds on constrained or expensive networks. Slow scans and failures increase the delay, up to ten minutes; polling pauses while asleep or offline. Finder controls when it runs the extension, so these are scheduling targets rather than guaranteed delivery times. No additional API key permissions are needed.

- **`apps/macos/immount/`**: the app. A settings window (General, Local Network, Statistics, About) and a menu bar item. It registers the File Provider domain, watches the Wi-Fi network, and schedules adaptive Finder refreshes while it runs.
- **`apps/macos/ImmountFileProvider/`**: a File Provider extension (`NSFileProviderReplicatedExtension`), the same system iCloud Drive uses. It lists folders, downloads originals on demand, and serves Immich thumbnails to Finder.
- **`apps/macos/ImmountKit/`**: a Swift package shared by both. It contains the Immich API client, the folder layout (`Catalog`), the store that diffs listings to report remote changes (`ListingStore`), and the settings, Keychain and connection code both targets share.

## Repository layout

This is a monorepo:

- **`apps/macos/`**: the Mac app, its File Provider extension and the shared Swift package (Xcode project).
- **`apps/website/`**: the presentation website (Next.js, Tailwind CSS and shadcn/ui), managed with the pnpm workspace at the root.

## Building

> [!NOTE]
> Immount is built with Xcode 27. Earlier versions of Xcode have not been tested.

The repository contains no signing identities or personal settings. You build Immount with your own Apple Developer account:

1. Copy `apps/macos/Config/Local.xcconfig.example` to `apps/macos/Config/Local.xcconfig` (git-ignored) and set:
   - `DEVELOPMENT_TEAM`: your team ID, from developer.apple.com > Account > Membership details.
   - `IMMOUNT_BUNDLE_ID`: a bundle identifier you own. The extension, app group and Keychain group are derived from it.
2. Open `apps/macos/immount.xcodeproj` in Xcode and run the `immount` scheme. Signing is automatic: the first build registers your Mac and creates the provisioning profiles that the app group and Keychain sharing need.

Without `IMMOUNT_UPDATE_FEED_URL` and `IMMOUNT_UPDATE_PUBLIC_KEY`, the build has no automatic updates and hides every update control. Set them only if you publish your own builds (see [Releasing](#releasing)).

Run the package tests with `swift test` in `apps/macos/ImmountKit/`. To also run them against a live server:

```sh
IMMICH_URL=https://demo.immich.app IMMICH_API_KEY=... swift test
```

Debug builds can connect without the UI:

```sh
IMMOUNT_SERVER=https://photos.example.com IMMOUNT_API_KEY=... path/to/Immount.app/Contents/MacOS/Immount
```

## Releasing

Releases are notarized with a Developer ID and published as GitHub releases. Each release carries the zipped app and `appcast.xml`, the Sparkle feed the app reads from `releases/latest/download/appcast.xml`.

One-time setup on the releasing Mac:

- [git-cliff](https://git-cliff.org): `brew install git-cliff`.
- A Developer ID Application certificate for your team.
- A Sparkle signing key: run Sparkle's `generate_keys` (see below for where it lives). It keeps the private key in your login Keychain and prints the public key. Back up the private key with `generate_keys -x <file>` and keep it safe: without it, existing installs can't verify new updates.
- In `Config/Local.xcconfig`, the feed of your GitHub repository and the public key:
  ```
  IMMOUNT_UPDATE_FEED_URL = https:/$()/github.com/<owner>/<repo>/releases/latest/download/appcast.xml
  IMMOUNT_UPDATE_PUBLIC_KEY = <public key>
  ```
  (`//` starts a comment in xcconfig files, hence `https:/$()/`.) The release script reads the repository from this URL.
- A notarytool profile: `xcrun notarytool store-credentials immount-notary --apple-id <id> --team-id <team>`.

Then, from `apps/macos/` with everything committed:

```sh
scripts/release.sh --preview   # the next version, build number and release notes
scripts/release.sh             # build, notarize and package that release
scripts/release.sh 2.0.0       # or pick the version yourself
```

Versions and release notes come from the commit messages (see [Contributing](#contributing)), through [git-cliff](https://git-cliff.org) and `cliff.toml`:

- `fix` and `perf` bump the patch version, `feat` the minor, a breaking change (`feat!:` or a `BREAKING CHANGE:` footer) the major. The first release uses the version in `Config/Version.xcconfig`.
- Only commits that touch `apps/macos/` count, so website changes never appear in the app's notes.
- The notes list the `feat`, `fix` and `perf` commits (plus any breaking change). They appear in the update window and on the GitHub release, and the script regenerates `CHANGELOG.md` from all releases.
- The build number is picked automatically: one more than the highest of `Config/Version.xcconfig` and every build already in the appcast (local and published), because Sparkle only installs a higher build.

The script asks for confirmation, then archives, exports with Developer ID, notarizes, staples, zips, and generates the signed appcast in `build/release/updates/`. After a successful build it writes the new version to `Config/Version.xcconfig` and regenerates `CHANGELOG.md`, then prints the commands that commit them, tag the release, push, and create the GitHub release. It never runs those itself. Sparkle's tools (`generate_keys`, `generate_appcast`, `sign_update`) are in `build/release/SourcePackages/artifacts/sparkle/Sparkle/bin/` after the first run.

To test an update before publishing, serve a folder with an appcast locally and point a Debug build at it:

```sh
path/to/Immount.app/Contents/MacOS/Immount -ImmountUpdateFeedURL http://localhost:8000/appcast.xml
```

## Website

```sh
pnpm install
pnpm dev      # http://localhost:3000
pnpm build
```

See `apps/website/README.md` for how the release card and screenshots work.

## Contributing

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/): `<type>(<optional scope>): <description>`, for example `fix(sync): keep albums current after deletes`. The release notes are generated from them, so write `feat`, `fix` and `perf` descriptions the way users should read them, with proper capitalization (`fix: handle an expired API key`). Other types (`chore`, `docs`, `refactor`, `test`, `ci`, `build`, `style`) stay out of the notes.

## License

Immount is released under the [MIT License](LICENSE).

## Not affiliated with Immich

Immount is an independent project and is not affiliated with or endorsed by Immich or FUTO.
