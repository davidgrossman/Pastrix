cask "pastrix" do
  version "1.4.0"
  sha256 "6c324fd2742b6d103c8994feb74acab7c57b504735c5a1d5ac9b187e4e500f1b"

  url "https://github.com/davidgrossman/Pastrix/releases/download/v#{version}/Pastrix-#{version}-macOS-arm64.dmg"
  name "Pastrix"
  desc "Clipboard manager with visual history, pinboards, and paste queues"
  homepage "https://davidgrossman.github.io/Pastrix/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Pastrix.app"

  caveats <<~EOS
    This early preview is ad-hoc signed and is not notarized.
    If macOS blocks launch, use System Settings > Privacy & Security > Open Anyway.
    Quit Paster or Pastrix before upgrading. Clipboard history is retained on uninstall.
    The public download is local-only; iCloud sync requires a provisioned build.
  EOS
end
