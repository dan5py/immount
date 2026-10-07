import { screenshots } from "@/components/screenshot"
import { formatVersion, type Release } from "@/lib/github"
import { links, site } from "@/lib/site"

/**
 * Describes the site and the app to search engines as JSON-LD. The WebSite entry gives Google
 * the site name to show in results instead of the domain.
 */
export function StructuredData({ release }: { release: Release | null }) {
  const website = {
    "@type": "WebSite",
    name: site.name,
    url: site.url,
  }

  const app = {
    "@type": "SoftwareApplication",
    name: site.name,
    description: site.description,
    url: site.url,
    image: `${site.url}/opengraph-image`,
    screenshot: Object.values(screenshots).map((shot) => `${site.url}${shot.src}`),
    applicationCategory: "MultimediaApplication",
    operatingSystem: `${site.minimumMacOS} or later`,
    isAccessibleForFree: true,
    offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
    license: "https://opensource.org/licenses/MIT",
    author: { "@type": "Person", ...site.author },
    sameAs: [links.github],
    ...(release && {
      softwareVersion: formatVersion(release.tag),
      datePublished: release.publishedAt,
      releaseNotes: release.url,
      downloadUrl: release.asset?.url ?? release.url,
    }),
  }

  const data = { "@context": "https://schema.org", "@graph": [website, app] }

  return (
    <script
      type="application/ld+json"
      // Escapes "<" so a release note can't close the script tag.
      dangerouslySetInnerHTML={{ __html: JSON.stringify(data).replace(/</g, "\\u003c") }}
    />
  )
}
