# Immount website

The presentation site for Immount: Next.js 16 (App Router, Cache Components), Tailwind CSS v4 and shadcn/ui.

```sh
pnpm install   # from the repository root
pnpm dev       # http://localhost:3000
pnpm build
```

The release card and download buttons read the latest GitHub release of `dan5py/immount` (set in `src/lib/site.ts`) and cache it for an hour. The first `.dmg`, `.zip` or `.pkg` asset becomes the download link; without a release the site shows build instructions instead. Set `GITHUB_TOKEN` to raise the API rate limit if needed.

Screenshots live in `public/screenshots/` as WebP captures of windows without their system shadow (`screencapture -o -l <window id>`); the page draws its own shadow. They were taken against the public Immich demo server.
