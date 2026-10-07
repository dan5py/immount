# Contributing to Immount

Thanks for helping. Bug reports, fixes and ideas are all welcome.

- **Questions** go in [Discussions](https://github.com/dan5py/immount/discussions/categories/q-a).
- **Bugs and feature requests** go in [issues](https://github.com/dan5py/immount/issues/new/choose).
- **Security problems** go in a [private advisory](https://github.com/dan5py/immount/security/advisories/new), never in a public issue. See [SECURITY.md](SECURITY.md).

For anything bigger than a small fix, open an issue first so we can agree on the approach before you spend time on it.

## Repository layout

| Path                             | What it is                                                          |
| -------------------------------- | ------------------------------------------------------------------- |
| `apps/macos/immount`             | The app: settings, menu bar icon, local network detection           |
| `apps/macos/ImmountFileProvider` | The File Provider extension that puts Immich in Finder              |
| `apps/macos/ImmountKit`          | Swift package shared by both: Immich API, settings, cache, Keychain |
| `apps/macos/Config`              | Build settings, entitlements, version                               |
| `apps/website`                   | [immount.app](https://immount.app), a Next.js site                  |

## Building the Mac app

1. Open `apps/macos/immount.xcodeproj` in Xcode.
2. Copy `apps/macos/Config/Local.xcconfig.example` to `apps/macos/Config/Local.xcconfig` (git-ignored) and set your team ID and a bundle identifier you own. The app and the File Provider extension share an app group, so they must be signed. Leave the Sparkle settings out to build without updates.
3. Run the `immount` scheme.

You need an Immich server to try it. A local one from the [Immich docs](https://immich.app/docs/install/docker-compose) works.

## Tests

CI runs the ImmountKit tests, which need no signing:

```sh
cd apps/macos/ImmountKit
swift test
```

Put logic in ImmountKit when you can, so it can be tested there. If you change the app or the extension, describe in the pull request how you tested it in Finder.

## Website

```sh
pnpm install
pnpm dev     # http://localhost:3000
pnpm lint
pnpm build
```

## Commits and pull requests

Pull requests are squash merged, and **the pull request title becomes the commit message**. Versions and [CHANGELOG.md](CHANGELOG.md) are generated from those messages with [git-cliff](https://git-cliff.org), so the title must follow [Conventional Commits](https://www.conventionalcommits.org) (a check enforces it):

```
<type>[(scope)][!]: <description>
```

- Types: `feat`, `fix`, `perf`, `refactor`, `docs`, `test`, `build`, `ci`, `chore`, `style`, `revert`.
- The description is lowercase and has no trailing period. Write it for users: `fix: keep the dock icon hidden after reopening the app`.
- `feat`, `fix` and `perf` changes to `apps/macos` appear in the release notes. Use the `website` scope for website changes; they never do.
- Mark a breaking change with `!`, e.g. `feat!: ...`.

Don't edit `CHANGELOG.md` or `apps/macos/Config/Version.xcconfig`: the release script writes them.

Keep pull requests focused on one change, and keep the code style of the files you touch.

## Code of Conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). By taking part you agree to it.
