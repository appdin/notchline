# url and sha256 are updated by .github/workflows/release.yml on each release.
class Notchline < Formula
  desc "Snow, weather and avalanche conditions for ski areas in the MacBook notch"
  homepage "https://github.com/appdin/notchline"
  url "https://github.com/appdin/notchline/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "Apache-2.0"
  head "https://github.com/appdin/notchline.git", branch: "main"

  depends_on xcode: ["16.0", :build]
  depends_on macos: :ventura

  def install
    swift_flags = "--disable-sandbox"
    system "make", "app", "SIGN_IDENTITY=-", "SWIFT_FLAGS=#{swift_flags}", "VERSION=#{version}"
    prefix.install "build/Notchline.app"

    # notchline-fetch finds locations.json in the resource bundle beside its real path.
    system "swift", "build", "-c", "release", swift_flags, "--product", "notchline-fetch"
    bin_dir = Utils.safe_popen_read("swift", "build", "-c", "release", swift_flags, "--show-bin-path").chomp
    libexec.install "#{bin_dir}/notchline-fetch", "#{bin_dir}/Notchline_NotchlineCore.bundle"
    bin.write_exec_script libexec/"notchline-fetch"
  end

  def caveats
    <<~EOS
      Notchline.app was built and installed to:
        #{opt_prefix}/Notchline.app
      To add it to /Applications:
        ln -sf #{opt_prefix}/Notchline.app /Applications/Notchline.app
    EOS
  end

  test do
    assert_match "mt-baker", shell_output("#{bin}/notchline-fetch --list")
  end
end
