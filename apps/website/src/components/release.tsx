import { ArrowUpRightIcon, DownloadIcon, PackageIcon } from "lucide-react"
import type { ReactNode } from "react"

import { SectionHeading } from "@/components/section-heading"
import { Badge } from "@/components/ui/badge"
import { buttonVariants } from "@/components/ui/button"
import { formatBytes, formatDate, formatVersion, type Release } from "@/lib/github"
import { links, site } from "@/lib/site"
import { cn } from "@/lib/utils"

export function ReleaseSection({ release }: { release: Release | null }) {
  return (
    <section id="release" className="mx-auto max-w-6xl px-6 py-28 sm:py-36">
      <SectionHeading title="What's new." />
      <div className="mx-auto mt-14 max-w-3xl">
        {release ? <ReleaseCard release={release} /> : <NoReleaseCard />}
      </div>
    </section>
  )
}

function ReleaseCard({ release }: { release: Release }) {
  const notes = summarizeNotes(release.notes)
  return (
    <article className="overflow-hidden rounded-3xl border bg-card shadow-sm">
      <header className="flex flex-wrap items-center gap-x-4 gap-y-2 border-b px-8 py-6">
        <div className="flex size-11 items-center justify-center rounded-xl bg-mac-blue/10 text-mac-blue">
          <PackageIcon className="size-5" />
        </div>
        <div className="min-w-0 flex-1">
          <h3 className="truncate text-xl font-semibold tracking-tight">{release.name}</h3>
          <p className="text-sm text-muted-foreground">
            Released <time dateTime={release.publishedAt}>{formatDate(release.publishedAt)}</time>
          </p>
        </div>
        {release.name === release.tag ? null : (
          <Badge variant="secondary" className="rounded-full font-mono">
            v{formatVersion(release.tag)}
          </Badge>
        )}
      </header>

      <div className="space-y-3 px-8 py-6 text-[0.95rem] leading-relaxed text-muted-foreground">
        {notes.length > 0 ? notes : <p>See the release page for details.</p>}
      </div>

      <footer className="flex flex-wrap items-center gap-3 border-t bg-muted/40 px-8 py-5">
        <a
          href={release.asset?.url ?? release.url}
          className={cn(
            buttonVariants(),
            "h-10 gap-2 rounded-full bg-mac-blue px-5 text-white hover:bg-mac-blue/90"
          )}
        >
          <DownloadIcon className="size-4" />
          Download
          {release.asset ? (
            <span className="font-normal text-white/75">{formatBytes(release.asset.size)}</span>
          ) : null}
        </a>
        <a
          href={release.url}
          className={cn(buttonVariants({ variant: "ghost" }), "h-10 gap-1.5 rounded-full px-4")}
        >
          Release notes
          <ArrowUpRightIcon className="size-4" />
        </a>
        <a
          href={links.releases}
          className="ml-auto text-sm text-muted-foreground underline-offset-4 hover:text-foreground hover:underline"
        >
          All releases
        </a>
      </footer>
    </article>
  )
}

function NoReleaseCard() {
  return (
    <article className="rounded-3xl border bg-card p-8 shadow-sm">
      <h3 className="text-xl font-semibold tracking-tight">The first release is on its way.</h3>
      <p className="mt-2 text-muted-foreground">Until then, build it with Xcode:</p>
      <ol className="mt-6 space-y-3 text-[0.95rem]">
        <Step n={1}>
          Clone{" "}
          <a href={links.github} className="font-medium text-mac-blue hover:underline">
            {site.repo}
          </a>
          .
        </Step>
        <Step n={2}>
          Open <code className="rounded bg-muted px-1.5 py-0.5 font-mono text-sm">apps/macos/immount.xcodeproj</code> in Xcode.
        </Step>
        <Step n={3}>
          Set your team in <code className="rounded bg-muted px-1.5 py-0.5 font-mono text-sm">Config/Local.xcconfig</code> and run the <code className="rounded bg-muted px-1.5 py-0.5 font-mono text-sm">immount</code> scheme.
        </Step>
      </ol>
      <a
        href={links.releases}
        className={cn(buttonVariants({ variant: "outline" }), "mt-8 h-10 gap-1.5 rounded-full px-5")}
      >
        Watch releases on GitHub
        <ArrowUpRightIcon className="size-4" />
      </a>
    </article>
  )
}

function Step({ n, children }: { n: number; children: ReactNode }) {
  return (
    <li className="flex gap-3">
      <span className="flex size-6 shrink-0 items-center justify-center rounded-full bg-mac-blue/10 text-xs font-semibold text-mac-blue">
        {n}
      </span>
      <span className="text-muted-foreground">{children}</span>
    </li>
  )
}

/** Renders the start of a Markdown release body: headings, bullets and paragraphs only. */
function summarizeNotes(markdown: string, maxBlocks = 10): ReactNode[] {
  const plain = (text: string) =>
    text
      .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")
      .replace(/(\*\*|__|`)/g, "")
      .trim()

  const blocks: ReactNode[] = []
  let bullets: string[] = []
  const flushBullets = () => {
    if (bullets.length === 0) return
    blocks.push(
      <ul key={`list-${blocks.length}`} className="list-disc space-y-1 pl-5">
        {bullets.map((bullet, index) => (
          <li key={index}>{bullet}</li>
        ))}
      </ul>
    )
    bullets = []
  }

  const withoutComments = markdown.replace(/<!--[\s\S]*?-->/g, "")
  for (const rawLine of withoutComments.split(/\r?\n/)) {
    if (blocks.length >= maxBlocks) break
    const line = rawLine.trim()
    if (!line) {
      flushBullets()
      continue
    }
    const bullet = line.match(/^[-*+]\s+(.*)$/)
    if (bullet) {
      bullets.push(plain(bullet[1]))
      continue
    }
    flushBullets()
    const heading = line.match(/^#{1,6}\s+(.*)$/)
    if (heading) {
      blocks.push(
        <h4 key={`h-${blocks.length}`} className="pt-2 font-semibold text-foreground">
          {plain(heading[1])}
        </h4>
      )
    } else {
      blocks.push(<p key={`p-${blocks.length}`}>{plain(line)}</p>)
    }
  }
  flushBullets()
  return blocks
}
