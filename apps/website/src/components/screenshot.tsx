import Image from "next/image"
import { cn } from "@/lib/utils"

export type ScreenshotProps = {
  src: string
  alt: string
  /** Pixel size of the 2x capture. */
  width: number
  height: number
  priority?: boolean
  sizes?: string
  className?: string
}

/**
 * A window captured without its system shadow. The shadow is drawn here so it follows the
 * window's rounded corners and adapts to the page's appearance.
 */
export function Screenshot({ src, alt, width, height, priority, sizes, className }: ScreenshotProps) {
  return (
    <Image
      src={src}
      alt={alt}
      width={width}
      height={height}
      priority={priority}
      sizes={sizes ?? "(min-width: 1024px) 960px, 100vw"}
      className={cn(
        "h-auto w-full select-none drop-shadow-[0_24px_48px_rgb(0_0_0/0.28)] dark:drop-shadow-[0_24px_60px_rgb(0_0_0/0.7)]",
        className
      )}
      draggable={false}
    />
  )
}

export const screenshots = {
  finderGallery: {
    src: "/screenshots/finder-gallery.webp",
    alt: "A Finder window in gallery view showing the Mountains album from an Immich server, with a large photo and a strip of thumbnails.",
    width: 1760,
    height: 1240,
  },
  finderColumns: {
    src: "/screenshots/finder-columns.webp",
    alt: "A Finder window in column view showing Immount's Timeline folder, organized by year and month.",
    width: 1760,
    height: 1180,
  },
  general: {
    src: "/screenshots/general.webp",
    alt: "Immount's General settings, showing the connected server, the Finder library and the cache.",
    width: 1430,
    height: 1280,
  },
  statistics: {
    src: "/screenshots/statistics.webp",
    alt: "Immount's Statistics pane, showing the server response time and a live download speed graph.",
    width: 1430,
    height: 1280,
  },
} satisfies Record<string, Omit<ScreenshotProps, "className" | "priority" | "sizes">>
