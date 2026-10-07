"use client"

import { Screenshot, screenshots } from "@/components/screenshot"
import { SectionHeading } from "@/components/section-heading"
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs"

const shots = [
  {
    value: "settings",
    label: "Settings",
    caption: "One window for the server, Finder, cache and visibility.",
    shot: screenshots.general,
  },
  {
    value: "statistics",
    label: "Statistics",
    caption: "Response time and live download speed, measured on your Mac.",
    shot: screenshots.statistics,
  },
  {
    value: "finder",
    label: "Finder",
    caption: "Gallery view of an album. Thumbnails come straight from Immich.",
    shot: screenshots.finderGallery,
  },
  {
    value: "timeline",
    label: "Timeline",
    caption: "The Timeline folder, organized by year and month.",
    shot: screenshots.finderColumns,
  },
]

export function Gallery() {
  return (
    <section id="screenshots" className="border-y bg-muted/40">
      <div className="mx-auto max-w-6xl px-6 py-28 sm:py-36">
        <SectionHeading title="Feels like it came with your Mac." />
        <Tabs defaultValue="settings" className="mt-12 items-center gap-10">
          <TabsList className="h-9 rounded-full p-1">
            {shots.map((item) => (
              <TabsTrigger key={item.value} value={item.value} className="rounded-full px-4">
                {item.label}
              </TabsTrigger>
            ))}
          </TabsList>
          {shots.map((item) => (
            <TabsContent key={item.value} value={item.value} className="w-full">
              <figure className="mx-auto flex max-w-4xl flex-col items-center">
                <div
                  className={
                    item.shot.width > 1500 ? "w-full" : "w-full max-w-2xl"
                  }
                >
                  <Screenshot {...item.shot} sizes="(min-width: 1024px) 896px, 100vw" />
                </div>
                <figcaption className="mt-8 text-center text-muted-foreground">
                  {item.caption}
                </figcaption>
              </figure>
            </TabsContent>
          ))}
        </Tabs>
        <p className="mt-10 text-center text-xs text-muted-foreground">
          Screenshots use the public Immich demo server.
        </p>
      </div>
    </section>
  )
}
