# Template for Casks/macpaper.rb in openappshq/homebrew-tap. The release
# workflow copies it there on the first release and sets version and sha256
# with packaging/homebrew/bump-cask.sh after every published release; until
# then it names no release (version 0.0.0, an all-zero digest) and cannot be
# installed.
cask "macpaper" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/openappshq/openapps/releases/download/macpaper-v#{version}/macPaper-#{version}.zip"
  name "macPaper"
  desc "Wallpapers your Mac makes itself, from the notch"
  homepage "https://openapps.space/macpaper/"

  # macPaper checks for updates itself; installing is opt-in. Homebrew shouldn’t fight it.
  auto_updates true
  depends_on macos: :sonoma

  # Installed into /Applications like a dragged disk image (Homebrew's
  # default; `--appdir` overrides it). Admin accounts need no password there.
  app "macPaper.app"

  # Signed with the stable OpenApps HQ Release certificate but not notarized:
  # clear the download quarantine so it opens without a Gatekeeper prompt,
  # then start it in the menu bar.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/macPaper.app"]
    system_command "/usr/bin/open",
                   args: ["#{appdir}/macPaper.app"]
  end

  uninstall quit: "com.openappshq.macpaper"

  zap trash: [
    "~/Library/Caches/com.openappshq.macpaper",
    "~/Library/HTTPStorages/com.openappshq.macpaper",
    "~/Library/Preferences/com.openappshq.macpaper.plist",
  ]
end
