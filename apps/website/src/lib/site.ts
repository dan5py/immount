export const site = {
  name: "Immount",
  url: "https://immount.app",
  tagline: "Immich in your Finder.",
  /** Kept under ~160 characters so search results show it whole. */
  description:
    "Immount is a free, open source Mac app that mounts your Immich library in the Finder sidebar. Browse albums, people and tags, and open originals in any app.",
  author: { name: "dan5py", url: "https://github.com/dan5py" },
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
