import { createHmac, timingSafeEqual } from "node:crypto"

import { revalidateTag } from "next/cache"

import { releaseCacheTag } from "@/lib/github"

/**
 * Receives the repository's GitHub webhook (content type application/json, "Releases"
 * event) and expires the cached release, so a new release appears without a rebuild.
 * GitHub signs each delivery with GITHUB_WEBHOOK_SECRET; unsigned requests are rejected.
 */
export async function POST(request: Request) {
  const secret = process.env.GITHUB_WEBHOOK_SECRET
  if (!secret) {
    return Response.json({ error: "GITHUB_WEBHOOK_SECRET is not set" }, { status: 503 })
  }

  const body = await request.text()
  if (!isSignedBy(secret, body, request.headers.get("x-hub-signature-256"))) {
    return Response.json({ error: "Invalid signature" }, { status: 401 })
  }

  const event = request.headers.get("x-github-event")
  if (event === "ping") {
    return Response.json({ ok: true })
  }
  if (event !== "release") {
    return Response.json({ ok: true, ignored: event })
  }

  // Published, edited, deleted: any of them can change what "latest" is. No stale copy,
  // so the next visit fetches the release instead of showing the old one once more.
  revalidateTag(releaseCacheTag, { expire: 0 })
  return Response.json({ ok: true, revalidated: releaseCacheTag })
}

/** Checks GitHub's `sha256=<hex>` HMAC of the raw body, in constant time. */
function isSignedBy(secret: string, body: string, signature: string | null) {
  if (!signature?.startsWith("sha256=")) return false
  const expected = Buffer.from(createHmac("sha256", secret).update(body).digest("hex"))
  const received = Buffer.from(signature.slice("sha256=".length))
  return expected.length === received.length && timingSafeEqual(expected, received)
}
