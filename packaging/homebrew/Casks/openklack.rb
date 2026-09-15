# Template for Casks/openklack.rb in openappshq/homebrew-tap. The release
# workflow copies it there on the first release and sets version and sha256
# with packaging/homebrew/bump-cask.sh after every published release; until
# then it names no release (version 0.0.0, an all-zero digest) and cannot be
# installed.
cask "openklack" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/openappshq/openapps/releases/download/openklack-v#{version}/OpenKlack-#{version}.zip"
  name "OpenKlack"
  desc "Mechanical keyboard sounds for the keyboard you already own"
  homepage "https://openapps.space/openklack/"

  # OpenKlack can update itself (off by default); Homebrew shouldn't fight it.
  auto_updates true
  depends_on macos: :sonoma

  # Installed into the user's Applications, so an in-app update never needs
  # an admin password.
  app "OpenKlack.app", target: "#{Dir.home}/Applications/OpenKlack.app"

  # Signed with the stable OpenApps HQ Release certificate but not notarized:
  # clear the download quarantine so it opens without a Gatekeeper prompt,
  # then start it in the menu bar.
  postflight_steps do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{Dir.home}/Applications/OpenKlack.app"]
    system_command "/usr/bin/open",
                   args: ["#{Dir.home}/Applications/OpenKlack.app"]
  end

  uninstall quit: "com.openklack.desktop"

  zap trash: [
    "~/Library/Application Support/com.openklack.desktop",
    "~/Library/Caches/com.openklack.desktop",
    "~/Library/Preferences/com.openklack.desktop.plist",
    "~/Library/WebKit/com.openklack.desktop",
  ]
end
