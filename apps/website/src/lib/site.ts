export const site = {
  name: "Immount",
  tagline: "Immich in your Finder.",
  description:
    "Immount mounts your Immich library as a folder in the Finder sidebar, like iCloud Drive. Browse albums, people, tags and your timeline, Quick Look photos, and drag originals into any app.",
  repo: "dan5py/immount",
  minimumMacOS: "macOS 14 Sonoma",
  testedImmich: "3.2",
} as const

export const links = {
  github: `https://github.com/${site.repo}`,
  releases: `https://github.com/${site.repo}/releases`,
  issues: `https://github.com/${site.repo}/issues`,
  immich: "https://immich.app",
  immichApi: "https://api.immich.app/",
} as const
