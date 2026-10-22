# Immount website

The presentation site for Immount: Next.js 16 (App Router, Cache Components), Tailwind CSS v4 and shadcn/ui.

```sh
pnpm install   # from the repository root
pnpm dev       # http://localhost:3000
pnpm build
```

The release card and download buttons read the latest GitHub release of `dan5py/immount` (set in `src/lib/site.ts`) and cache it for five minutes, with a hard expiry of ten minutes. The first `.dmg`, `.zip` or `.pkg` asset becomes the download link; without a release the site shows build instructions instead. Set `GITHUB_TOKEN` to raise the API rate limit if needed.

A new release shows up right away through a GitHub webhook, which expires the cached release. In the repository's Settings > Webhooks, add one with payload URL `https://<site>/api/github-webhook`, content type `application/json`, a random secret, and only the "Releases" event. Set the same secret as `GITHUB_WEBHOOK_SECRET` on the server. Without the webhook, the next visit after five minutes triggers a refresh.

Screenshots live in `public/screenshots/` as WebP captures of windows without their system shadow (`screencapture -o -l <window id>`); the page draws its own shadow. They were taken against the public Immich demo server.

The social preview image is drawn by `src/app/opengraph-image.tsx` at build time. Its renderer can't read WebP or Google Fonts, so it uses the PNG screenshot and Inter TTFs in `assets/og/`; re-export the PNG when `finder-gallery.webp` changes (`sips -s format png --resampleWidth 1100 public/screenshots/finder-gallery.webp --out assets/og/finder-gallery.png`).

Page analytics use [Umami](https://umami.is). Set `NEXT_PUBLIC_UMAMI_SCRIPT_URL` (e.g. `https://umami.example.com/script.js`) and `NEXT_PUBLIC_UMAMI_WEBSITE_ID` at build time; without both, no tracking script is loaded.
