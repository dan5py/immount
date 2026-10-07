import Image from "next/image";

import { HomeLink } from "@/components/home-link";
import { GitHubIcon } from "@/components/icons";
import { buttonVariants } from "@/components/ui/button";
import { links, site } from "@/lib/site";
import { cn } from "@/lib/utils";

const sections = [
  { href: "#features", label: "Features" },
  { href: "#screenshots", label: "Screenshots" },
  { href: "#release", label: "Release" },
  { href: "#faq", label: "FAQ" },
];

export function SiteHeader({ downloadHref }: { downloadHref: string }) {
  return (
    <header className="sticky top-0 z-50 border-b border-border/60 bg-background/70 backdrop-blur-xl backdrop-saturate-150">
      <div className="mx-auto flex h-14 max-w-6xl items-center gap-6 px-6">
        <HomeLink className="flex items-center gap-2.5 font-semibold tracking-tight">
          <Image
            src="/images/app-icon.svg"
            alt=""
            width={28}
            height={28}
            className="size-7"
          />
          {site.name}
        </HomeLink>
        <nav
          aria-label="Sections"
          className="hidden items-center gap-1 text-sm text-muted-foreground md:flex"
        >
          {sections.map((section) => (
            <a
              key={section.href}
              href={section.href}
              className="rounded-full px-3 py-1.5 transition-colors hover:bg-muted hover:text-foreground"
            >
              {section.label}
            </a>
          ))}
        </nav>
        <div className="ml-auto flex items-center gap-2">
          <a
            href={links.github}
            aria-label="Immount on GitHub"
            className={cn(
              buttonVariants({ variant: "ghost", size: "icon" }),
              "rounded-full",
            )}
          >
            <GitHubIcon className="size-4.5" />
          </a>
          <a
            href={downloadHref}
            className={cn(
              buttonVariants({ size: "sm" }),
              "rounded-full bg-mac-blue px-3.5 text-white hover:bg-mac-blue/90",
            )}
          >
            Download
          </a>
        </div>
      </div>
    </header>
  );
}
