"use client"

import Link from "next/link"
import { usePathname } from "next/navigation"
import type { ComponentProps, MouseEvent } from "react"

/**
 * Links to the home page. On the home page itself a link to the current page does nothing in
 * the browser, so this scrolls up and clears any section hash instead.
 */
export function HomeLink(props: Omit<ComponentProps<typeof Link>, "href" | "onClick">) {
  const pathname = usePathname()

  function scrollToTop(event: MouseEvent<HTMLAnchorElement>) {
    if (pathname !== "/") return
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
    event.preventDefault()
    window.scrollTo({ top: 0, behavior: "smooth" })
    history.replaceState(null, "", window.location.pathname)
  }

  return <Link href="/" onClick={scrollToTop} {...props} />
}
