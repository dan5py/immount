const features = [
  { title: "Just a folder.", text: "Immich sits in the Finder sidebar, next to iCloud Drive." },
  { title: "Nothing to sync.", text: "Originals download only when you open them." },
  { title: "Always current.", text: "New photos and albums appear within seconds." },
  { title: "Faster at home.", text: "Talks to your server directly on your home Wi-Fi." },
  { title: "Read-only.", text: "Immount never changes anything on your server." },
  { title: "Private.", text: "Your API key stays in the Keychain." },
]

export function Features() {
  return (
    <section id="features" className="mx-auto max-w-6xl px-6 py-28 sm:py-36">
      <h2 className="max-w-3xl text-4xl font-bold tracking-tight text-balance sm:text-6xl">
        Your library, where your files already are.
      </h2>
      <dl className="mt-16 grid gap-x-12 gap-y-12 sm:mt-20 sm:grid-cols-2 lg:grid-cols-3">
        {features.map((feature) => (
          <div key={feature.title} className="border-t pt-6">
            <dt className="text-xl font-semibold tracking-tight">{feature.title}</dt>
            <dd className="mt-2 text-muted-foreground">{feature.text}</dd>
          </div>
        ))}
      </dl>
    </section>
  )
}
