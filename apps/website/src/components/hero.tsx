import { DownloadIcon } from "lucide-react";
import Image from "next/image";

import { GitHubIcon } from "@/components/icons";
import { Screenshot, screenshots } from "@/components/screenshot";
import { buttonVariants } from "@/components/ui/button";
import { formatVersion, type Release } from "@/lib/github";
import { links, site } from "@/lib/site";
import { cn } from "@/lib/utils";

export function Hero({
  release,
  downloadHref,
}: {
  release: Release | null;
  downloadHref: string;
}) {
  return (
    <section className="relative overflow-hidden">
      <Glow />
      <div className="relative mx-auto flex max-w-6xl flex-col items-center px-6 pt-20 text-center sm:pt-28">
        <Image
          src="/images/app-icon.svg"
          alt="The Immount app icon"
          width={128}
          height={128}
          priority
          className="size-28 drop-shadow-[0_18px_30px_rgb(0_0_0/0.25)] sm:size-32"
        />
        <h1 className="mt-8 text-5xl font-bold tracking-tight text-balance sm:text-7xl">
          {site.tagline}
        </h1>
        <p className="mt-6 max-w-xl text-lg text-pretty text-muted-foreground sm:text-xl">
          Your{" "}
          <a
            href={links.immich}
            className="text-foreground underline-offset-4 hover:underline"
          >
            Immich
          </a>{" "}
          library as a folder on your Mac.
        </p>

        <div className="mt-10 flex flex-col items-center gap-3 sm:flex-row">
          <a
            href={downloadHref}
            className={cn(
              buttonVariants({ size: "lg" }),
              "h-12 gap-2 rounded-full bg-mac-blue px-6 text-base text-white shadow-lg shadow-mac-blue/25 hover:bg-mac-blue/90",
            )}
          >
            <DownloadIcon className="size-5" />
            {release ? `Download ${formatVersion(release.tag)}` : "Get Immount"}
          </a>
          <a
            href={links.github}
            className={cn(
              buttonVariants({ variant: "outline", size: "lg" }),
              "h-12 gap-2 rounded-full px-6 text-base",
            )}
          >
            <GitHubIcon className="size-5" />
            View on GitHub
          </a>
        </div>
        <p className="mt-4 text-sm text-muted-foreground">
          Free and open source · macOS 14 or later
        </p>

        <div className="mt-16 w-full max-w-5xl sm:mt-20">
          <Screenshot
            {...screenshots.finderGallery}
            priority
            sizes="(min-width: 1024px) 1024px, 100vw"
          />
        </div>
      </div>
    </section>
  );
}

/** Soft color wash in the app icon's folder colors. */
function Glow() {
  return (
    <div
      aria-hidden="true"
      className="pointer-events-none absolute inset-0 -z-0"
    >
      <div className="absolute top-[38%] left-1/2 h-[42rem] w-[70rem] -translate-x-1/2 opacity-40 blur-3xl dark:opacity-30">
        <div className="absolute top-0 left-[8%] size-[26rem] rounded-full bg-[#ec4899]" />
        <div className="absolute top-[10%] left-[32%] size-[24rem] rounded-full bg-[#ef4444]" />
        <div className="absolute top-[4%] right-[24%] size-[26rem] rounded-full bg-[#f59e0b]" />
        <div className="absolute top-[30%] right-[6%] size-[24rem] rounded-full bg-[#22c55e]" />
        <div className="absolute top-[36%] left-[22%] size-[26rem] rounded-full bg-[#3b82f6]" />
      </div>
      <div className="absolute inset-x-0 bottom-0 h-40 bg-gradient-to-b from-transparent to-background" />
    </div>
  );
}
