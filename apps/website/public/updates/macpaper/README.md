# macPaper update feed

`appcast.xml` here is served at `https://openapps.space/updates/macpaper/appcast.xml`,
the feed official macPaper builds check (RELEASES.md, "Update feed"). The
release workflow (`.github/workflows/macpaper.yml`, the `feed` job) writes it
with `apps/macpaper/scripts/make-appcast.sh`, signs it with macPaper's update key,
and commits it to `main` only after the release's zip is published and
verified; nothing else should edit it. Installed apps verify the feed's
signature against the public key compiled into them
(`apps/macpaper/release/sparkle-public-key.txt`), so a hand-edited feed is
ignored. `/updates/*` is served with a five-minute cache (`apps/website/headers.ts`).

To pull a bad release, restore the previous `appcast.xml` from git history
and ship the fix as a higher version. There is no feed until the first
release with the updater.
