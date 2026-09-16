# Template for Casks/opennotes.rb in openappshq/homebrew-tap. The release
# workflow copies it there on the first release and sets version and sha256
# with packaging/homebrew/bump-cask.sh after every published release; until
# then it names no release (version 0.0.0, an all-zero digest) and cannot be
# installed.
cask "opennotes" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/openappshq/openapps/releases/download/opennotes-v#{version}/OpenNotes-#{version}.zip"
  name "OpenNotes"
  desc "Sticky notes docked to the edge of your screen"
  homepage "https://openapps.space/opennotes/"

  # OpenNotes checks for updates itself; installing is opt-in. Homebrew shouldn’t fight it.
  auto_updates true
  depends_on macos: :sonoma

  # Installed into /Applications like a dragged disk image (Homebrew's
  # default; `--appdir` overrides it). Admin accounts need no password there.
  app "OpenNotes.app"

  # Signed with the stable OpenApps HQ Release certificate but not notarized:
  # clear the download quarantine so it opens without a Gatekeeper prompt,
  # then start it.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/OpenNotes.app"], must_succeed: false
    run "/usr/bin/open", args: ["{{appdir}}/OpenNotes.app"], must_succeed: false
  end

  uninstall quit: "com.openappshq.opennotes"

  # `--zap` removes the app's own data: preferences, caches and the license
  # and trial records in Application Support. The notes themselves are plain
  # files in the folder the user chose (~/Documents/OpenNotes by default) and
  # are never touched.
  zap trash: [
    "~/Library/Application Support/OpenApps/opennotes",
    "~/Library/Caches/com.openappshq.opennotes",
    "~/Library/HTTPStorages/com.openappshq.opennotes",
    "~/Library/Preferences/com.openappshq.opennotes.plist",
  ]
end
