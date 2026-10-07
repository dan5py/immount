import { FolderIcon } from "lucide-react"

import { Screenshot, screenshots } from "@/components/screenshot"

const folders = ["Albums", "Favorites", "People", "Tags", "Timeline"]

export function LibraryLayout() {
  return (
    <section className="border-y bg-muted/40">
      <div className="mx-auto grid max-w-6xl items-center gap-14 px-6 py-28 sm:py-36 lg:grid-cols-[2fr_3fr]">
        <div>
          <h2 className="text-4xl font-bold tracking-tight text-balance sm:text-5xl">
            Every photo, one folder away.
          </h2>
          <ul className="mt-8 space-y-3">
            {folders.map((folder) => (
              <li key={folder} className="flex items-center gap-3 text-lg font-medium">
                <FolderIcon className="size-5 fill-[#5ac8fa] text-[#34aadc]" aria-hidden="true" />
                {folder}
              </li>
            ))}
          </ul>
        </div>
        <Screenshot {...screenshots.finderColumns} sizes="(min-width: 1024px) 640px, 100vw" />
      </div>
    </section>
  )
}
