import { AppIcon } from "@/components/app-icon"
import { GitHubIcon } from "@/components/icons"
import { links, site } from "@/lib/site"

export function SiteFooter() {
  return (
    <footer className="border-t">
      <div className="mx-auto flex max-w-6xl flex-col gap-6 px-6 py-10 text-sm text-muted-foreground sm:flex-row sm:items-center">
        <div className="flex items-center gap-2.5">
          <AppIcon aria-hidden="true" className="size-6" />
          <span className="font-medium text-foreground">{site.name}</span>
        </div>
        <p className="sm:flex-1">
          Not affiliated with or endorsed by Immich or FUTO.
        </p>
        <nav aria-label="Footer" className="flex items-center gap-5">
          <a href={links.releases} className="hover:text-foreground">
            Releases
          </a>
          <a href={links.issues} className="hover:text-foreground">
            Report an issue
          </a>
          <a href={links.github} aria-label="GitHub" className="hover:text-foreground">
            <GitHubIcon className="size-4.5" />
          </a>
        </nav>
      </div>
    </footer>
  )
}
