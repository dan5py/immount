"use client"

import Link from "next/link"
import type { ComponentProps, MouseEvent } from "react"

/**
 * Links to the top of the page. A link to the current page does nothing in the browser,
 * so this scrolls up and clears any section hash instead.
 */
export function HomeLink(props: Omit<ComponentProps<typeof Link>, "href" | "onClick">) {
  function scrollToTop(event: MouseEvent<HTMLAnchorElement>) {
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
    event.preventDefault()
    window.scrollTo({ top: 0, behavior: "smooth" })
    history.replaceState(null, "", window.location.pathname)
  }

  return <Link href="/" onClick={scrollToTop} {...props} />
}
