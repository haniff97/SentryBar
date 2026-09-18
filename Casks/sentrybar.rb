cask "sentrybar" do
  version "1.0.0"
  # Replace with the SHA-256 printed by ./scripts/make-dmg.sh on each release.
  sha256 "REPLACE_WITH_DMG_SHA256"

  url "https://github.com/haniff97/SentryBar/releases/download/v#{version}/SentryBar.dmg"
  name "SentryBar"
  desc "Menu-bar system monitor and controls (temps, fans, display, keyboard lock)"
  homepage "https://github.com/haniff97/SentryBar"

  app "SentryBar.app"

  caveats <<~EOS
    SentryBar is ad-hoc signed (not notarized). If macOS blocks the first
    launch, run once:
      xattr -cr "/Applications/SentryBar.app"

    Keyboard Lock needs Accessibility + Input Monitoring permissions
    (System Settings > Privacy & Security), then relaunch the app.
  EOS
end
