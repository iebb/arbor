# Homebrew cask for Arbor. It needs a notarized release (Homebrew rejects quarantined, unsigned apps
# for most users), so publish it to a tap such as iebb/homebrew-tap once releases are notarized:
#   brew install --cask iebb/tap/arbor
# Update `version` and `sha256` (from the release's .sha256 file) for each release.
cask "arbor" do
  version "0.3.0"
  sha256 "REPLACE_WITH_RELEASE_SHA256"

  url "https://github.com/iebb/arbor/releases/download/v#{version}/Arbor-#{version}.zip"
  name "Arbor"
  desc "File manager that works like Windows File Explorer"
  homepage "https://github.com/iebb/arbor"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: ">= :sonoma"

  app "Arbor.app"

  zap trash: [
    "~/Library/Caches/io.github.iebb.arbor",
    "~/Library/Containers/io.github.iebb.arbor",
    "~/Library/Preferences/io.github.iebb.arbor.plist",
  ]
end
