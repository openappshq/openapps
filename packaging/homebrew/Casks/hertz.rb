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

  # Hertz checks for updates itself; installing is opt-in. Homebrew shouldn’t fight it.
  auto_updates true
  depends_on macos: :sonoma

  # Installed into /Applications like a dragged disk image (Homebrew's
  # default; `--appdir` overrides it). Admin accounts need no password there.
  app "Hertz.app"

  # Signed with the stable OpenApps HQ Release certificate but not notarized:
  # clear the download quarantine so it opens without a Gatekeeper prompt,
  # then start it in the menu bar.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/Hertz.app"], must_succeed: false
    run "/usr/bin/open", args: ["{{appdir}}/Hertz.app"], must_succeed: false
  end

  uninstall quit: "com.openappshq.hertz"

  zap trash: [
    "~/Library/Caches/com.openappshq.hertz",
    "~/Library/HTTPStorages/com.openappshq.hertz",
    "~/Library/Preferences/com.openappshq.hertz.plist",
  ]
end
