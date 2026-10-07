import { Faq } from "@/components/faq"
import { Features } from "@/components/features"
import { Gallery } from "@/components/gallery"
import { Hero } from "@/components/hero"
import { LibraryLayout } from "@/components/library-layout"
import { MenuBarSection } from "@/components/menu-bar"
import { ReleaseSection } from "@/components/release"
import { SiteFooter } from "@/components/site-footer"
import { SiteHeader } from "@/components/site-header"
import { StructuredData } from "@/components/structured-data"
import { getLatestRelease } from "@/lib/github"

export default async function Home() {
  const release = await getLatestRelease()
  // Straight to the installer when there is one, otherwise to the release section.
  const downloadHref = release?.asset?.url ?? "#release"

  return (
    <>
      <StructuredData release={release} />
      <SiteHeader downloadHref={downloadHref} />
      <main className="flex-1">
        <Hero release={release} downloadHref={downloadHref} />
        <Features />
        <LibraryLayout />
        <MenuBarSection />
        <Gallery />
        <ReleaseSection release={release} />
        <Faq />
      </main>
      <SiteFooter />
    </>
  )
}
