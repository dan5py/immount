import { readFile } from "node:fs/promises";
import { join } from "node:path";

import { ImageResponse } from "next/og";

import { site } from "@/lib/site";

export const alt = `${site.name}: ${site.tagline} A Finder window showing an Immich album.`;
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

// The renderer reads only TTF/OTF/WOFF and PNG/JPEG/SVG, so the page's WebP screenshot and
// Google Fonts don't work here: these copies live in assets/og. Literal paths keep the build
// from tracing the whole project.
const [interMedium, interBold, icon, screenshot] = await Promise.all([
  readFile(join(process.cwd(), "assets/og/Inter-Medium.ttf")),
  readFile(join(process.cwd(), "assets/og/Inter-Bold.ttf")),
  readFile(join(process.cwd(), "public/images/app-icon.svg")),
  readFile(join(process.cwd(), "assets/og/finder-gallery.png")),
]);

const dataUrl = (data: Buffer, type: string) =>
  `data:${type};base64,${data.toString("base64")}`;

const glow = [
  "radial-gradient(circle at 8% 0%, rgb(236 72 153 / 0.30), transparent 42%)",
  "radial-gradient(circle at 46% 4%, rgb(245 158 11 / 0.16), transparent 38%)",
  "radial-gradient(circle at 96% 18%, rgb(34 197 94 / 0.22), transparent 40%)",
  "radial-gradient(circle at 70% 100%, rgb(59 130 246 / 0.38), transparent 50%)",
  "linear-gradient(135deg, #1a2436 0%, #0f1626 60%, #0b1020 100%)",
].join(", ");

export default function Image() {
  return new ImageResponse(
    <div
      style={{
        display: "flex",
        width: "100%",
        height: "100%",
        backgroundImage: glow,
        color: "white",
        fontFamily: "Inter",
      }}
    >
      <div
        style={{
          display: "flex",
          flexDirection: "column",
          width: 560,
          padding: "64px 0 60px 72px",
        }}
      >
        <div style={{ display: "flex", alignItems: "center", gap: 18 }}>
          <img
            src={dataUrl(icon, "image/svg+xml")}
            width={72}
            height={72}
            alt=""
          />
          <span
            style={{ fontSize: 34, fontWeight: 700, letterSpacing: "-0.02em" }}
          >
            {site.name}
          </span>
        </div>
        <div
          style={{
            marginTop: 64,
            fontSize: 76,
            fontWeight: 700,
            lineHeight: 1.04,
            letterSpacing: "-0.035em",
          }}
        >
          {site.tagline}
        </div>
        <div
          style={{
            display: "flex",
            flexDirection: "column",
            marginTop: 26,
            fontSize: 30,
            fontWeight: 500,
            lineHeight: 1.3,
            color: "rgb(255 255 255 / 0.66)",
          }}
        >
          <span>Your Immich library</span>
          <span>as a folder on your Mac.</span>
        </div>
        <div
          style={{
            display: "flex",
            marginTop: "auto",
            fontSize: 22,
            fontWeight: 500,
            color: "rgb(255 255 255 / 0.5)",
          }}
        >
          {`Free and open source · ${new URL(site.url).host}`}
        </div>
      </div>
      <div
        style={{
          display: "flex",
          position: "absolute",
          top: 118,
          left: 586,
          overflow: "hidden",
          borderRadius: 19,
          border: "1px solid rgb(255 255 255 / 0.16)",
          boxShadow: "0 30px 70px rgb(0 0 0 / 0.55)",
        }}
      >
        <img
          src={dataUrl(screenshot, "image/png")}
          width={760}
          height={536}
          alt=""
        />
      </div>
    </div>,
    {
      ...size,
      fonts: [
        { name: "Inter", data: interMedium, weight: 500, style: "normal" },
        { name: "Inter", data: interBold, weight: 700, style: "normal" },
      ],
    },
  );
}
