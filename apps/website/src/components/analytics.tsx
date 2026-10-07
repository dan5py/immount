import Script from "next/script";

/**
 * Umami page analytics
 */
export function Analytics() {
  const src = process.env.NEXT_PUBLIC_UMAMI_SCRIPT_URL;
  const websiteId = process.env.NEXT_PUBLIC_UMAMI_WEBSITE_ID;
  if (!src || !websiteId) return null;

  return (
    <Script src={src} data-website-id={websiteId} strategy="afterInteractive" />
  );
}
