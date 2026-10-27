# App Store listing

```
AppStore/
├─ metadata/<locale>/        name, subtitle, description, keywords, promo text, What's New
│  ├─ en-US/
│  └─ pl/
└─ screenshots/
   ├─ <lang>/iphone-6.9/     captioned, 1320 × 2868, upload these
   ├─ <lang>/ipad-13/        captioned, 2064 × 2752
   └─ raw/                   the plain simulator captures they're made from
```

The folders follow fastlane `deliver`'s layout. Upload them with `fastlane deliver`,
or paste the text and drag the images into App Store Connect.

## Regenerating screenshots

```sh
scripts/appstore-screenshots.sh
```

This builds the app and runs it in the iPhone 17 Pro Max (6.9") and iPad Pro 13" simulators, in light mode with a 9:41 status bar. The demo household comes from `SampleData.seedScreenshots` (Emma & Jack in USD, Ania & Kuba in PLN) and is DEBUG builds only. The captions are added by `scripts/compose-screenshots.swift`; change the headlines there. Six screens: the list grouped by aisle, checkout, balances, the invitation (QR / AirDrop), history and the lists overview.

The data in the screenshots is fake, and nothing in them comes from a real account.

## What App Store Connect will also ask for

- **Privacy Policy URL:** https://jiwaszek.github.io/TogetherList/privacy/ (`docs/privacy/`)
- **Support URL:** https://jiwaszek.github.io/TogetherList/support/ (`docs/support/`)

  Both are served by GitHub Pages from `/docs` on `main`, and are also in `metadata/<locale>/privacy_url.txt` and `support_url.txt`.
- **Category:** suggested *Productivity*, with *Food & Drink* as the secondary category.
- **Age rating:** no objectionable content, so the questionnaire should give 4+.
- **App Privacy** (suggested answers; check them against your own policy):
  - *Contact Info → Email Address*: collected for the account, linked to the user, not used for tracking.
  - *Contact Info → Name*: the display name, same answers as email.
  - *Identifiers → User ID*: the account ID, same answers.
  - *User Content → Other User Content*: lists, items, notes, purchases and payments, same answers.
  - No tracking, no third-party analytics and no advertising data.
- **Sign-in for App Review:** reviewers need a working account. Create one in your Supabase project, share a list from a second account so the shared features are visible, and enter the credentials under *App Review Information*.
- **Encryption:** `ITSAppUsesNonExemptEncryption` is already `NO` in `Config/Info.plist`, because the app only uses standard HTTPS. App Store Connect won't ask about export compliance.
