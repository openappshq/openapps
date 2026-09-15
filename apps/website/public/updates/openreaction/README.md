# OpenReaction update feed

`appcast.xml` here is served at `https://openapps.space/updates/openreaction/appcast.xml`,
the feed official OpenReaction builds check (RELEASES.md, "Update feed"). The
release workflow writes it with `apps/openreaction/scripts/make-appcast.sh`,
signs it with the update key, and commits it through
`scripts/release/commit-feed.sh` only after the release's zip is published
and verified; nothing else should edit it. Installed apps verify the feed's
signature against the public key compiled into them, so a hand-edited feed
is ignored.

To pull a bad release, restore the previous `appcast.xml` from git history
and ship the fix as a higher version. There is no feed until the first
release.
