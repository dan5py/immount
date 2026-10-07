# Immount website

The presentation site for Immount: Next.js 16 (App Router, Cache Components), Tailwind CSS v4 and shadcn/ui.

```sh
pnpm install   # from the repository root
pnpm dev       # http://localhost:3000
pnpm build
```

The release card and download buttons read the latest GitHub release of `dan5py/immount` (set in `src/lib/site.ts`) and cache it for an hour. The first `.dmg`, `.zip` or `.pkg` asset becomes the download link; without a release the site shows build instructions instead. Set `GITHUB_TOKEN` to raise the API rate limit if needed.

A new release shows up right away through a GitHub webhook, which expires the cached release. In the repository's Settings > Webhooks, add one with payload URL `https://<site>/api/github-webhook`, content type `application/json`, a random secret, and only the "Releases" event. Set the same secret as `GITHUB_WEBHOOK_SECRET` on the server. Without the webhook the release updates within the hour.

Screenshots live in `public/screenshots/` as WebP captures of windows without their system shadow (`screencapture -o -l <window id>`); the page draws its own shadow. They were taken against the public Immich demo server.

The social preview image is drawn by `src/app/opengraph-image.tsx` at build time. Its renderer can't read WebP or Google Fonts, so it uses the PNG screenshot and Inter TTFs in `assets/og/`; re-export the PNG when `finder-gallery.webp` changes (`sips -s format png --resampleWidth 1100 public/screenshots/finder-gallery.webp --out assets/og/finder-gallery.png`).
