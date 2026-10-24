# version and sha256 are updated by .github/workflows/release.yml on each release.
cask "notchline" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/appdin/notchline/releases/download/v#{version}/Notchline-#{version}.zip"
  name "Notchline"
  desc "Snow, weather and avalanche conditions for ski areas in the MacBook notch"
  homepage "https://github.com/appdin/notchline"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :ventura"

  app "Notchline.app"

  uninstall quit: "com.appdin.notchline"

  zap trash: [
    "~/Library/Application Support/Notchline",
    "~/Library/Preferences/com.appdin.notchline.plist",
  ]
end
