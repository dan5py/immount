import { Faq } from "@/components/faq"
import { Features } from "@/components/features"
import { Gallery } from "@/components/gallery"
import { Hero } from "@/components/hero"
import { LibraryLayout } from "@/components/library-layout"
import { MenuBarSection } from "@/components/menu-bar"
import { ReleaseSection } from "@/components/release"
import { StructuredData } from "@/components/structured-data"
import { getDownloadHref, getLatestRelease } from "@/lib/github"

export default async function Home() {
  const release = await getLatestRelease()

  return (
    <>
      <StructuredData release={release} />
      <main className="flex-1">
        <Hero release={release} downloadHref={getDownloadHref(release)} />
        <Features />
        <LibraryLayout />
        <MenuBarSection />
        <Gallery />
        <ReleaseSection release={release} />
        <Faq />
      </main>
    </>
  )
}
