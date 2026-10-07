import type { SVGProps } from "react";

import { MenuBarGlyph } from "@/components/icons";
import { cn } from "@/lib/utils";

type MenuItem =
  | { kind: "status"; label: string }
  | { kind: "action"; label: string; shortcut?: string }
  | { kind: "info"; label: string }
  | { kind: "separator" };

const items: MenuItem[] = [
  { kind: "status", label: "Connected" },
  { kind: "action", label: "Show in Finder" },
  { kind: "action", label: "Refresh Now" },
  { kind: "info", label: "Last refresh: 12 seconds ago" },
  { kind: "separator" },
  { kind: "action", label: "Settings…", shortcut: "⌘," },
  { kind: "action", label: "Quit Immount", shortcut: "⌘Q" },
];

export function MenuBarSection() {
  return (
    <section className="mx-auto grid max-w-6xl items-center gap-14 px-6 py-28 sm:py-36 lg:grid-cols-2">
      <MenuBarMock />
      <div className="lg:order-first">
        <h2 className="text-4xl font-bold tracking-tight text-balance sm:text-5xl">
          Quietly keeps Finder in sync.
        </h2>
        <p className="mt-5 max-w-md text-lg text-pretty text-muted-foreground">
          Lives in the menu bar, or nowhere at all. <br />
          Quit it and the folder goes away.
        </p>
      </div>
    </section>
  );
}

/** A static recreation of Immount's menu bar menu, in the macOS menu style. */
function MenuBarMock() {
  return (
    <div
      role="img"
      aria-label="Immount's menu bar menu: Connected, Show in Finder, Refresh Now, Last refresh 12 seconds ago, Settings, Quit Immount."
      className="relative isolate h-64 overflow-hidden rounded-3xl shadow-xl"
    >
      <div aria-hidden="true" className="wallpaper absolute inset-0 -z-10" />
      {/* The macOS Tahoe menu bar: no bar of its own, just glyphs over the wallpaper. */}
      <div className="flex h-9 items-center justify-end gap-[18px] px-4 text-[13px] font-medium text-neutral-900 dark:text-white">
        {/* The open item gets a capsule, and its menu hangs from the item's left edge. */}
        <span className="relative -mx-1 flex h-[26px] items-center rounded-full bg-black/10 px-2.5 dark:bg-white/20">
          <MenuBarGlyph className="size-[17px]" />
          <Menu className="absolute top-[calc(100%+5px)] left-0" />
        </span>
        <WifiGlyph className="h-[15px]" />
        <BatteryGlyph className="h-[13px]" />
        <SearchGlyph className="h-[15px]" />
        <ControlCenterGlyph className="h-[15px]" />
        <span className="flex gap-2 tabular-nums">
          <span className="hidden sm:inline">Tue Apr 1</span>
          <span>9:41 AM</span>
        </span>
      </div>
      <div
        aria-hidden="true"
        className="pointer-events-none absolute inset-0 rounded-[inherit] ring-1 ring-black/10 ring-inset dark:ring-white/10"
      />
    </div>
  );
}

function Menu({ className }: { className?: string }) {
  return (
    <div
      className={cn(
        "w-64 rounded-[14px] border border-black/10 bg-white/80 p-[5px] text-[13px] font-normal text-neutral-900 shadow-2xl backdrop-blur-2xl dark:border-white/10 dark:bg-neutral-800/80 dark:text-neutral-100",
        className,
      )}
    >
      {items.map((item, index) => (
        <MenuRow key={index} item={item} highlighted={index === 1} />
      ))}
    </div>
  );
}

function MenuRow({
  item,
  highlighted,
}: {
  item: MenuItem;
  highlighted: boolean;
}) {
  if (item.kind === "separator") {
    return <div className="mx-2.5 my-1 h-px bg-black/10 dark:bg-white/15" />;
  }
  return (
    <div
      className={cn(
        "flex h-[26px] items-center justify-between rounded-[9px] px-2.5",
        item.kind !== "action" && "text-neutral-500 dark:text-neutral-400",
        highlighted && "bg-mac-blue text-white",
      )}
    >
      <span>{item.label}</span>
      {item.kind === "action" && item.shortcut ? (
        <span
          className={cn(
            "text-neutral-500 dark:text-neutral-400",
            highlighted && "text-white/80",
          )}
        >
          {item.shortcut}
        </span>
      ) : null}
    </div>
  );
}

/* Menu bar glyphs drawn after SF Symbols, sized for a 13 pt menu bar. */

function WifiGlyph(props: SVGProps<SVGSVGElement>) {
  return (
    <svg
      viewBox="0 0 20 15"
      fill="currentColor"
      stroke="currentColor"
      strokeWidth={1.1}
      strokeLinejoin="round"
      aria-hidden="true"
      {...props}
    >
      <path d="M10 14.6L7.85 12.37A3.1 3.1 0 0 1 12.15 12.37Z" />
      <path d="M4.72 9.13A7.6 7.6 0 0 1 15.28 9.13L13.47 11A5 5 0 0 0 6.53 11Z" />
      <path d="M1.59 5.9A12.1 12.1 0 0 1 18.41 5.9L16.6 7.77A9.5 9.5 0 0 0 3.4 7.77Z" />
    </svg>
  );
}

function BatteryGlyph(props: SVGProps<SVGSVGElement>) {
  return (
    <svg viewBox="0 0 27 13" fill="none" aria-hidden="true" {...props}>
      <rect
        x="0.6"
        y="0.6"
        width="22.8"
        height="11.8"
        rx="3.6"
        stroke="currentColor"
        strokeOpacity={0.45}
        strokeWidth={1.2}
      />
      <rect
        x="2.4"
        y="2.4"
        width="19.2"
        height="8.2"
        rx="2"
        fill="currentColor"
      />
      <path
        d="M25 4.4c1 .3 1.5 1.1 1.5 2.1s-.5 1.8-1.5 2.1z"
        fill="currentColor"
        fillOpacity={0.45}
      />
    </svg>
  );
}

function SearchGlyph(props: SVGProps<SVGSVGElement>) {
  return (
    <svg
      viewBox="0 0 15 15"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.6}
      strokeLinecap="round"
      aria-hidden="true"
      {...props}
    >
      <circle cx="6.2" cy="6.2" r="5.1" />
      <path d="M10 10l4 4" />
    </svg>
  );
}

function ControlCenterGlyph(props: SVGProps<SVGSVGElement>) {
  return (
    <svg viewBox="0 0 17 15" aria-hidden="true" {...props}>
      {/* Top switch: off, knob on the left. */}
      <rect
        x="0.7"
        y="0.7"
        width="15.6"
        height="5.8"
        rx="2.9"
        fill="none"
        stroke="currentColor"
        strokeWidth={1.3}
      />
      <circle cx="3.6" cy="3.6" r="2.15" fill="currentColor" />
      {/* Bottom switch: on, filled with the knob cut out on the right. */}
      <path
        fillRule="evenodd"
        fill="currentColor"
        d="M3.6 8h9.8a3.6 3.6 0 0 1 0 7.2H3.6a3.6 3.6 0 0 1 0-7.2Zm9.8 1.4a2.2 2.2 0 1 0 0 4.4 2.2 2.2 0 0 0 0-4.4Z"
      />
    </svg>
  );
}
