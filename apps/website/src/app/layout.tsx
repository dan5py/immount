import type { Metadata, Viewport } from "next"
import { Geist_Mono, Inter } from "next/font/google"

import { Analytics } from "@/components/analytics"
import { SiteFooter } from "@/components/site-footer"
import { SiteHeader } from "@/components/site-header"
import { getDownloadHref, getLatestRelease } from "@/lib/github"
import { site } from "@/lib/site"

import "./globals.css"

const inter = Inter({
  variable: "--font-inter",
  subsets: ["latin"],
})

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
})

const title = `${site.name}: ${site.tagline}`

// The Open Graph image comes from app/opengraph-image.tsx; Twitter falls back to it.
export const metadata: Metadata = {
  metadataBase: new URL(site.url),
  title: { default: title, template: `%s · ${site.name}` },
  description: site.description,
  applicationName: site.name,
  authors: [site.author],
  creator: site.author.name,
  category: "photography",
  alternates: { canonical: "/" },
  openGraph: {
    title,
    description: site.description,
    url: "/",
    type: "website",
    siteName: site.name,
    locale: "en_US",
  },
  twitter: {
    card: "summary_large_image",
    title,
    description: site.description,
  },
}

export const viewport: Viewport = {
  themeColor: [
    { media: "(prefers-color-scheme: light)", color: "#ffffff" },
    { media: "(prefers-color-scheme: dark)", color: "#0a0a0a" },
  ],
}

// The header and footer live here, not in each page: Next.js keeps the scroll position when the
// top of the new page is in view, and a sticky header at the top of a page always is.
export default async function RootLayout({ children }: LayoutProps<"/">) {
  const release = await getLatestRelease()

  return (
    <html lang="en" className={`${inter.variable} ${geistMono.variable} h-full antialiased`}>
      <body className="flex min-h-full flex-col">
        <SiteHeader downloadHref={getDownloadHref(release)} />
        {children}
        <SiteFooter />
        <Analytics />
      </body>
    </html>
  )
}
