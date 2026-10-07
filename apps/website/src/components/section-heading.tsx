import type { ReactNode } from "react"

export function SectionHeading({ title }: { title: ReactNode }) {
  return (
    <h2 className="mx-auto max-w-2xl text-center text-4xl font-bold tracking-tight text-balance sm:text-5xl">
      {title}
    </h2>
  )
}
