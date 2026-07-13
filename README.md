# AscKit

Copy-in toolkit for App Store Connect releases: screenshots, TestFlight, and IAP helpers.

Not a Swift package. Drop the templates + scripts into your iOS app and wire them with env vars.

## What’s inside

```
AscKit/
├── LICENSE
├── Gemfile
├── Templates/
│   ├── Fastfile              # beta, upload_screenshots, stage_screenshots
│   ├── Appfile.example
│   ├── ExportOptions.plist
│   └── .asc.env.example
└── Scripts/
    ├── release-testflight.sh
    ├── stage-app-store-screenshots.sh
    ├── check-screenshots.rb
    ├── check-build-status.rb
    ├── setup-iap.rb
    ├── replace-iap-screenshot.rb
    └── attach-build-and-submit.rb
```

## Setup

**1. Copy into your app**

```bash
cp -R /path/to/AscKit/Templates .
cp -R /path/to/AscKit/Scripts .
# merge AscKit/Gemfile into yours (or copy it)
```

**2. Wire Fastlane**

```bash
mkdir -p fastlane
mv Templates/Fastfile fastlane/Fastfile
cp Templates/Appfile.example fastlane/Appfile
```

**3. Add your ASC API key**

```bash
cp Templates/.asc.env.example Scripts/.asc.env
```

Fill in `ASC_KEY_ID`, `ASC_ISSUER_ID`, and `ASC_KEY_PATH` (path to your `.p8`). Never commit `.asc.env` or `.p8` files.

Also set your app identity (in `.asc.env` or your shell):

```bash
export ASC_BUNDLE_ID=com.example.MyApp
export ASC_TEAM_ID=TEAMID1234
export ASC_XCODE_PROJECT=MyApp.xcodeproj
export ASC_XCODE_SCHEME=MyApp
```

**4. Install Fastlane (optional if you only use the bash script)**

```bash
bundle install
```

## Common commands

```bash
# Screenshots
bundle exec fastlane ios stage_screenshots
bundle exec fastlane ios upload_screenshots
ruby Scripts/check-screenshots.rb

# TestFlight — Fastlane
bundle exec fastlane ios beta

# TestFlight — plain bash (no Ruby)
Scripts/release-testflight.sh
Scripts/release-testflight.sh --validate-only

# IAP
ruby Scripts/setup-iap.rb
ruby Scripts/replace-iap-screenshot.rb
BUILD_VERSION=4 ruby Scripts/attach-build-and-submit.rb
BUILD_VERSION=4 ruby Scripts/attach-build-and-submit.rb --submit
```

## Env vars you’ll use most

| Variable | Purpose |
|---|---|
| `ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_KEY_PATH` | App Store Connect API key |
| `ASC_BUNDLE_ID` | Bundle ID |
| `ASC_TEAM_ID` | Apple Developer team |
| `ASC_XCODE_PROJECT` / `ASC_XCODE_SCHEME` | What to archive |
| `SCREENSHOT_LOCALE` | ASC locale folder, e.g. `en-US` |
| `IPHONE_SCREENSHOTS` / `IPAD_SCREENSHOTS` | PNG source folders |
| `IAP_PRODUCT_ID` / `IAP_PRICE` / `IAP_SCREENSHOT` | IAP setup |
| `BUILD_VERSION` | Build number to attach for review |

## Heads-up on first IAP submission

Almost everything about IAP setup can be scripted. Selecting an IAP for its **first** review submission with a version is still **UI-only** in App Store Connect — the public API does not expose that step. After `setup-iap.rb`, open the version page, pick the IAP under “In-App Purchases and Subscriptions”, then submit.

## License

MIT — see [LICENSE](LICENSE).
