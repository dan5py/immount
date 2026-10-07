import { cacheLife, cacheTag } from "next/cache"

import { site } from "@/lib/site"

/** Tags the cached release; the GitHub webhook expires it when a release changes. */
export const releaseCacheTag = "github-release"

export type ReleaseAsset = {
  name: string
  url: string
  size: number
}

export type Release = {
  tag: string
  name: string
  url: string
  publishedAt: string
  notes: string
  asset: ReleaseAsset | null
}

type GitHubAsset = {
  name: string
  browser_download_url: string
  size: number
}

type GitHubRelease = {
  tag_name: string
  name: string | null
  html_url: string
  published_at: string | null
  body: string | null
  assets: GitHubAsset[]
}

/** Preferred download formats, best first. */
const installerPatterns = [/\.dmg$/i, /\.zip$/i, /\.pkg$/i]

function pickInstaller(assets: GitHubAsset[]): ReleaseAsset | null {
  for (const pattern of installerPatterns) {
    const match = assets.find((asset) => pattern.test(asset.name))
    if (match) {
      return { name: match.name, url: match.browser_download_url, size: match.size }
    }
  }
  return null
}

/**
 * The latest published release, or null when there is none yet or GitHub is unreachable.
 * Cached for an hour so the page stays static and the API rate limit is never a concern.
 * A release published on GitHub shows up right away through the webhook in
 * `app/api/github-webhook`.
 */
export async function getLatestRelease(): Promise<Release | null> {
  "use cache"
  cacheLife("hours")
  cacheTag(releaseCacheTag)

  const headers: HeadersInit = {
    Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
  }
  if (process.env.GITHUB_TOKEN) {
    headers.Authorization = `Bearer ${process.env.GITHUB_TOKEN}`
  }

  try {
    const response = await fetch(`https://api.github.com/repos/${site.repo}/releases/latest`, {
      headers,
    })
    if (!response.ok) return null
    const release = (await response.json()) as GitHubRelease
    return {
      tag: release.tag_name,
      name: release.name?.trim() || release.tag_name,
      url: release.html_url,
      publishedAt: release.published_at ?? new Date().toISOString(),
      notes: release.body?.trim() ?? "",
      asset: pickInstaller(release.assets),
    }
  } catch {
    return null
  }
}

export function formatVersion(tag: string) {
  return tag.replace(/^v/i, "")
}

export function formatBytes(bytes: number) {
  if (bytes < 1024 * 1024) return `${Math.max(1, Math.round(bytes / 1024))} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}

export function formatDate(iso: string) {
  return new Intl.DateTimeFormat("en", { dateStyle: "long" }).format(new Date(iso))
}
