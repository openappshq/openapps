# Template for Casks/openreaction.rb in openappshq/homebrew-tap. The release
# workflow copies it there on the first release and sets version and sha256
# with packaging/homebrew/bump-cask.sh after every published release; until
# then it names no release (version 0.0.0, an all-zero digest) and cannot be
# installed.
cask "openreaction" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/openappshq/openapps/releases/download/openreaction-v#{version}/OpenReaction-#{version}.zip"
  name "OpenReaction"
  desc "Emoji suggestions for every text field: type :shortcode: anywhere"
  homepage "https://openapps.space/openreaction/"

  # OpenReaction can update itself (off by default); Homebrew shouldn't fight it.
  auto_updates true
  depends_on macos: :sonoma

  # Installed into /Applications like a dragged disk image (Homebrew's
  # default; `--appdir` overrides it). Admin accounts need no password there.
  app "OpenReaction.app"

  # Signed with the stable OpenApps HQ Release certificate but not notarized:
  # clear the download quarantine so it opens without a Gatekeeper prompt,
  # then start it in the menu bar.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/OpenReaction.app"]
    system_command "/usr/bin/open",
                   args: ["#{appdir}/OpenReaction.app"]
  end

  uninstall quit: "com.openappshq.openreaction"

  zap trash: [
    "~/Library/Caches/com.openappshq.openreaction",
    "~/Library/HTTPStorages/com.openappshq.openreaction",
    "~/Library/Preferences/com.openappshq.openreaction.plist",
  ]
end
