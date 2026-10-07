# Security policy

## Reporting a vulnerability

Report it privately through [GitHub's private vulnerability reporting](https://github.com/dan5py/immount/security/advisories/new). Don't open a public issue, discussion or pull request.

Include what you found, how to reproduce it, and the Immount, macOS and Immich versions. You'll get a reply within a week. Once a fix is released, the advisory is published and you're credited, unless you prefer not to be.

## Supported versions

Only the latest release gets security fixes. Immount updates itself through Sparkle, so the fix reaches users as a regular update.

## Scope

Immount stores an Immich API key and talks to your server, so these matter most:

- The API key leaving the Keychain, or being sent anywhere other than the server you entered, for example through a redirect.
- The local URL being used on a network where it isn't safe, which could send requests and the key to another device.
- The File Provider extension exposing files or data outside the Immich location in Finder.
- Problems in how updates are downloaded or verified.

Vulnerabilities in Immich itself belong to the [Immich project](https://github.com/immich-app/immich/security).
