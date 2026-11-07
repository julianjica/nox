# Homebrew cask for nox. This repository is its own tap:
#   brew tap julianjica/nox https://github.com/julianjica/nox
#   brew install --cask --no-quarantine nox
# It always installs the latest release (upgrade with `brew upgrade --cask --greedy nox`).
cask "nox" do
  version :latest
  sha256 :no_check

  url "https://github.com/julianjica/nox/releases/latest/download/nox.zip"
  name "nox"
  desc "Keyboard-driven PDF viewer with notes stored in the PDF"
  homepage "https://github.com/julianjica/nox"

  depends_on macos: ">= :ventura"

  app "nox.app"
  binary "#{appdir}/nox.app/Contents/Resources/nox-cli", target: "nox"

  zap trash: [
    "~/Library/Preferences/com.jujimenez.nox.plist",
    "~/.config/nox",
  ]
end
