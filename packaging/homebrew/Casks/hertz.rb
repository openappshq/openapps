# Template for Casks/hertz.rb in openappshq/homebrew-tap. The release
# workflow copies it there on the first release and sets version and sha256
# with packaging/homebrew/bump-cask.sh after every published release; until
# then it names no release (version 0.0.0, an all-zero digest) and cannot be
# installed.
cask "hertz" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/openappshq/openapps/releases/download/hertz-v#{version}/Hertz-#{version}.zip"
  name "Hertz"
  desc "Native macOS menu-bar system monitor"
  homepage "https://openapps.space/hertz/"

  # Hertz has no in-app updater; Homebrew is the only update path, so let it
  # report and install upgrades as usual.
  auto_updates false
  depends_on macos: :sonoma

  # Installed into the user's Applications: no admin password to install or
  # upgrade.
  app "Hertz.app", target: "#{Dir.home}/Applications/Hertz.app"

  # Signed with the stable OpenApps HQ Release certificate but not notarized:
  # clear the download quarantine so it opens without a Gatekeeper prompt,
  # then start it in the menu bar.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{Dir.home}/Applications/Hertz.app"]
    system_command "/usr/bin/open",
                   args: ["#{Dir.home}/Applications/Hertz.app"]
  end

  uninstall quit: "com.openappshq.hertz"

  zap trash: [
    "~/Library/Preferences/com.openappshq.hertz.plist",
  ]
end
