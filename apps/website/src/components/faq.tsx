import type { ReactNode } from "react"

import { SectionHeading } from "@/components/section-heading"
import {
  Accordion,
  AccordionContent,
  AccordionItem,
  AccordionTrigger,
} from "@/components/ui/accordion"
import { links, site } from "@/lib/site"

const permissions = [
  ["asset.read", "Listing photos and videos"],
  ["asset.view", "Thumbnails in Finder"],
  ["asset.download", "Opening originals"],
  ["album.read", "Albums"],
  ["person.read", "People"],
  ["tag.read", "Tags and their hierarchy"],
  ["user.read", "Checking the key"],
] as const

/** Only the Statistics pane uses these; Finder works without them. */
const optionalPermissions = [
  ["asset.statistics", "Library counts"],
  ["server.storage", "Server disk usage"],
] as const

const questions: { question: string; answer: ReactNode }[] = [
  {
    question: "What do I need?",
    answer: `A Mac with ${site.minimumMacOS} or later and an Immich server (tested with ${site.testedImmich}).`,
  },
  {
    question: "Which API key permissions does it need?",
    answer: (
      <>
        <p>
          <Code>all</Code>, or just these:
        </p>
        <PermissionList permissions={permissions} />
        <p className="mt-5">Optional, for the Statistics pane:</p>
        <PermissionList permissions={optionalPermissions} />
      </>
    ),
  },
  {
    question: "Does it download my whole library?",
    answer: "No. Only the files you open, and you can clear them anytime in Settings.",
  },
  {
    question: "What happens when I quit?",
    answer: "The folder leaves Finder. Open Immount again and it's back right away.",
  },
  {
    question: "Is it affiliated with Immich?",
    answer: (
      <>
        No, Immount is an independent project, not endorsed by{" "}
        <a href={links.immich} className="text-mac-blue hover:underline">
          Immich
        </a>{" "}
        or FUTO.
      </>
    ),
  },
]

export function Faq() {
  return (
    <section id="faq" className="border-t bg-muted/40">
      <div className="mx-auto max-w-3xl px-6 py-28 sm:py-36">
        <SectionHeading title="Questions and answers." />
        <Accordion className="mt-12 rounded-2xl border bg-card px-6">
          {questions.map((item) => (
            <AccordionItem key={item.question} value={item.question}>
              <AccordionTrigger className="py-5 text-base">{item.question}</AccordionTrigger>
              <AccordionContent className="pb-5 text-[0.95rem] leading-relaxed text-muted-foreground">
                {item.answer}
              </AccordionContent>
            </AccordionItem>
          ))}
        </Accordion>
      </div>
    </section>
  )
}

function PermissionList({ permissions }: { permissions: readonly (readonly [string, string])[] }) {
  return (
    <dl className="mt-3 grid grid-cols-[auto_1fr] gap-x-6 gap-y-2">
      {permissions.map(([permission, use]) => (
        <div key={permission} className="contents">
          <dt>
            <Code>{permission}</Code>
          </dt>
          <dd>{use}</dd>
        </div>
      ))}
    </dl>
  )
}

function Code({ children }: { children: ReactNode }) {
  return (
    <code className="rounded bg-muted px-1.5 py-0.5 font-mono text-[0.85em] text-foreground">
      {children}
    </code>
  )
}
