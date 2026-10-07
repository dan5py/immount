import type { Metadata } from "next";
import type { ReactNode } from "react";

import { links, site } from "@/lib/site";

const description = `How ${site.name} handles your data: local app storage, connections to your Immich server, website analytics, hosting, and your privacy choices.`;

export const metadata: Metadata = {
  title: "Privacy policy",
  description,
  alternates: { canonical: "/privacy" },
  openGraph: {
    title: `Privacy policy · ${site.name}`,
    description,
    url: "/privacy",
    type: "website",
    siteName: site.name,
    locale: "en_US",
  },
  twitter: {
    card: "summary_large_image",
    title: `Privacy policy · ${site.name}`,
    description,
  },
};

/** Update when the policy changes; the full history is in the repository. */
const lastUpdated = "2026-10-07";

/**
 * Draft review before publication:
 * - Supply the controller's legal identity.
 * - Establish retention periods or meaningful deletion criteria for analytics and logs.
 * - Validate the analytics legal basis, any consent requirements and transfer arrangements
 *   against the deployed Umami/Cloudflare configuration and applicable agreements.
 * The text below describes the confirmed setup; it does not change that setup.
 */
export default function Privacy() {
  return (
    <main className="flex-1">
      <article className="mx-auto max-w-2xl px-6 py-20 sm:py-28">
        <h1 className="text-4xl font-bold tracking-tight sm:text-5xl">
          Privacy policy
        </h1>
        <p className="mt-4 text-sm text-muted-foreground">
          Last updated{" "}
          <time dateTime={lastUpdated}>{formatDate(lastUpdated)}</time>
        </p>

        <p className="mt-10 text-lg text-pretty">
          {site.name} connects your Mac to the Immich server you choose. The app
          does not send your photos, API key or library data to me. It stores
          data on your Mac to make your library available in Finder. The website
          uses self-hosted analytics to understand how it is used.
        </p>

        <Section title="About this policy">
          <p>
            This policy covers <A href={site.url}>immount.app</A> and the
            official {site.name} macOS app. I am{" "}
            <A href={site.author.url}>{site.author.name}</A>, the project&apos;s
            maintainer and the person responsible for the website and the
            information you choose to send me. In this policy, &ldquo;I&rdquo;
            and &ldquo;me&rdquo; refer to that role.
          </p>
          <p>
            Your Immich server is operated by you or the provider you choose.
            Its handling of your account, photos and server logs is separate
            from this policy. You do not need an account with {site.name} to use
            the website or app.
          </p>
        </Section>

        <Section title="Data on your Mac">
          <p>
            {site.name} processes the information needed to browse and open your
            library:
          </p>
          <ul className="flex list-disc flex-col gap-3 pl-5">
            <li>
              <strong className="font-medium text-foreground">
                Connection details.
              </strong>{" "}
              Your server addresses, Immich user ID and preferences are saved
              locally. Your API key is stored in the macOS Keychain and sent to
              your configured Immich server to authenticate requests.
            </li>
            <li>
              <strong className="font-medium text-foreground">
                Library information and files.
              </strong>{" "}
              The app caches folder listings and metadata, such as filenames,
              albums, people, tags, dates and file sizes. Finder requests
              thumbnails and downloads originals as needed. Downloaded originals
              are stored on your Mac through macOS File Provider.
            </li>
            <li>
              <strong className="font-medium text-foreground">
                Local statistics and diagnostics.
              </strong>{" "}
              The Statistics feature records download counts, transferred bytes
              and speeds on your Mac. You can turn it off in Settings; doing so
              keeps previously saved totals. The app also writes diagnostic
              messages to macOS logs. It does not include a service that sends
              usage analytics or crash reports to me.
            </li>
            <li>
              <strong className="font-medium text-foreground">
                Optional Wi-Fi detection.
              </strong>{" "}
              If you set up a local server address, the app can use your Wi-Fi
              network name to choose between local and remote connections. macOS
              requires Location Services permission to read this name.{" "}
              {site.name} does not request geographic coordinates; your selected
              network names are stored on your Mac.
            </li>
          </ul>
          <p>
            In Settings,{" "}
            <strong className="font-medium text-foreground">Clear Cache</strong>{" "}
            requests removal of downloaded originals. Files in use or kept
            downloaded may remain; this control does not clear library metadata
            or thumbnails.{" "}
            <strong className="font-medium text-foreground">
              Forget Server
            </strong>{" "}
            removes the saved connection, its Keychain entry and its saved
            library listings and statistics. These actions do not delete photos
            from Immich or revoke the key on your server. Copies you save
            elsewhere and macOS-managed logs or caches may remain separately.
          </p>
        </Section>

        <Section title="Connections and app updates">
          <p>
            Library requests go to the Immich server addresses you configure.
            That server receives your API key and the connection information
            needed to answer those requests. Use an HTTPS address when you need
            the connection to be encrypted.
          </p>
          <p>
            The app uses Sparkle to check for updates and download them from
            GitHub. GitHub and its download infrastructure receive your IP
            address and ordinary request information, including the app version.
            You can turn off automatic update checks in Settings under About. A
            manual check or download still contacts GitHub.
          </p>
        </Section>

        <Section title="Website analytics">
          <p>
            I use <A href="https://umami.is">Umami</A>, hosted on a Hetzner
            server in the EU, to measure visits, see which pages people use and
            improve the website. This analytics setup does not set analytics
            cookies or use advertising trackers.
          </p>
          <p>Page-view records include:</p>
          <ul className="flex list-disc flex-col gap-1 pl-5">
            <li>
              the page URL and title, referring URL, and time of the visit
            </li>
            <li>URL parameters and fragments, when present</li>
            <li>
              browser, operating system, device type, screen size and language
            </li>
            <li>
              approximate location, such as country, region or city, derived
              from the connection
            </li>
            <li>
              generated identifiers used to group page views and estimate visits
            </li>
          </ul>
          <p>
            Umami processes your IP address to derive location information and
            generate statistical identifiers using the website, browser
            information and a rotating salt. It does not store the raw IP
            address in its analytics records. I use the page-view and session
            records to produce usage reports. Hosting and security logs are
            separate and may contain IP addresses.
          </p>
          <p>
            You can prevent these analytics requests with a browser content
            blocker that blocks <span>umami.dan5py.com</span>. The website
            remains usable without the analytics script.
          </p>
        </Section>

        <Section title="Hosting and service providers">
          <p>
            The website and analytics service run on servers I manage at{" "}
            <A href="https://www.hetzner.com/legal/privacy-policy/">Hetzner</A>,
            with{" "}
            <A href="https://www.cloudflare.com/privacypolicy/">Cloudflare</A>{" "}
            providing delivery and protection against abuse. Serving and
            protecting requests involves processing IP addresses, requested
            URLs, timestamps, browser information and security events. This
            information may appear in access or security logs.
          </p>
          <p>
            Depending on the security checks applied, Cloudflare may use{" "}
            <A href="https://developers.cloudflare.com/fundamentals/reference/policies-compliances/cloudflare-cookies/">
              security cookies
            </A>
            . The absence of Umami cookies does not mean that every service
            involved in delivering the website is cookie-free.
          </p>
          <p>
            Source code, downloads and issue discussions are hosted on GitHub.
            Visiting those pages, downloading the app or checking for updates
            involves GitHub&apos;s services, covered by its{" "}
            <A href="https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement">
              privacy statement
            </A>
            .
          </p>
          <p>
            Cloudflare and GitHub operate internationally and may process
            information outside the European Economic Area. EU hosting of the
            analytics database does not mean all request data stays in the EU.
            Cloudflare describes its transfer safeguards in its{" "}
            <A href="https://www.cloudflare.com/cloudflare-customer-dpa/">
              data processing terms
            </A>
            ; GitHub describes its safeguards in its privacy statement.
          </p>
          <p>
            I do not sell your personal information or use it for targeted
            advertising. Providers process information as needed to supply their
            services, as described above.
          </p>
        </Section>

        <Section title="Information you choose to share">
          <p>
            If you email me, open a GitHub issue or otherwise contact me, I
            receive the information you provide, such as your email address,
            username, message and attachments. I use it to answer your request and investigate
            problems. Public issues and comments can be read by anyone. Do not
            post API keys, private server addresses, personal photos or
            unredacted logs.
          </p>
        </Section>

        <Section title="Purposes and legal basis">
          <p>
            Where I process personal data to operate and secure the website,
            understand its use through basic audience statistics, or respond to
            requests, I rely on legitimate interests under Article 6(1)(f) GDPR.
            Those interests are maintaining a reliable website, preventing abuse
            and supporting and improving the project. You may object to
            processing based on legitimate interests.
          </p>
          <p>
            I do not use this information for automated decisions that have
            legal or similarly significant effects on you.
          </p>
        </Section>

        <Section title="How long information is kept">
          <p>
            There is currently no fixed retention period for the self-hosted
            analytics records or the access and security logs I control. They
            may remain stored until deleted. This applies to the underlying
            records, not only to summary statistics. Service providers may
            retain their own operational records under their respective terms
            and policies.
          </p>
          <p>
            Information on your Mac remains subject to the app&apos;s storage
            controls and macOS cache management described above. GitHub issues
            and comments may remain part of the public project history after an
            issue is closed.
          </p>
        </Section>

        <Section title="Your rights and contact">
          <p>
            Where the GDPR applies, you may request access, correction, deletion
            or restriction of your personal data, object to processing, and
            request data portability where applicable. I may be unable to
            associate analytics records with you. If so, I will explain that
            limitation; it does not automatically rule out a request.
          </p>
          <p>
            For questions about this policy or to exercise your privacy rights,
            email <A href="mailto:help@immount.app">help@immount.app</A>.
            Please include only the information needed to handle your request.
            Requests are normally answered within one month; if an extension is
            permitted and needed, I will explain why.
          </p>
          <p>
            You may also complain to your local data protection authority,
            including the{" "}
            <A href="https://www.garanteprivacy.it">
              Garante per la protezione dei dati personali
            </A>{" "}
            in Italy.
          </p>
        </Section>

        <Section title="Changes">
          <p>
            I will update this page and its date when this policy changes. You
            can inspect the <A href={links.github}>app&apos;s source code</A>{" "}
            and the policy&apos;s committed{" "}
            <A
              href={`${links.github}/commits/main/apps/website/src/app/privacy/page.tsx`}
            >
              repository history
            </A>
            .
          </p>
        </Section>
      </article>
    </main>
  );
}

function Section({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="mt-14">
      <h2 className="text-2xl font-semibold tracking-tight">{title}</h2>
      <div className="mt-5 flex flex-col gap-4 leading-relaxed text-muted-foreground">
        {children}
      </div>
    </section>
  );
}

function A({ href, children }: { href: string; children: ReactNode }) {
  return (
    <a href={href} className="text-mac-blue hover:underline">
      {children}
    </a>
  );
}

function formatDate(iso: string) {
  return new Intl.DateTimeFormat("en", {
    dateStyle: "long",
    timeZone: "UTC",
  }).format(new Date(iso));
}
