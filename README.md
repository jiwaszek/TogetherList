# TogetherList

A native iOS shopping-list app for sharing lists with a partner, family or friends.
People connect once by scanning a QR code or opening an invitation link. They stay
connected until someone disconnects. Changes sync live between everyone on a list,
and the app keeps working offline.

- **Platform:** iOS / iPadOS **17.0+**. iOS 17 is needed for the Observation framework (`@Observable`) and `ContentUnavailableView`. Built with Xcode 27.1, Swift 6 language mode.
- **Backend:** [Supabase](https://supabase.com) (Postgres, row-level security, SQL functions, Realtime, Auth) via `supabase-swift` 2.55.x.

## Why Supabase

The hard requirements are server-side: permissions enforced on the backend,
**atomic and idempotent** invitation acceptance, and consistent revocation when
two people disconnect. Postgres covers all three directly:

- Row-level security (RLS) policies decide who can read and write each row. Hiding a button in the app never grants or denies access.
- Multi-step operations, such as accepting an invitation or disconnecting, are `SECURITY DEFINER` SQL functions. Each one runs in a single transaction, so it either fully happens or doesn't happen at all.
- Realtime "Postgres Changes" delivers row changes to subscribers. RLS filters what each subscriber receives.
- Auth gives every user a stable UUID, and the app ships only the publishable key.

Firebase could do this too, but the atomic acceptance and the disconnect cascade
would need Cloud Functions plus fairly involved security rules.

## Architecture

```
TogetherList (app target, SwiftUI only)
 ├─ App/            AppModel (composition root, session, deep links), config, network monitor
 ├─ Features/       Onboarding · Lists · ListDetail · Sharing · Scanner · Invitations · Members · Settings
 └─ Shared/         Avatar, sync status pill, notice banner

TogetherListKit (local Swift package)
 ├─ TogetherListCore      no third-party dependencies, unit-tested with `swift test`
 │   ├─ Models/           AuthUser, UserProfile, ShoppingList, ListMember, ShoppingItem,
 │   │                    Connection, Invitation*, AppError, QuickEntryParser
 │   ├─ Backend/          BackendService protocol, ItemDraft, ItemPatch, RemoteChange
 │   ├─ Sync/             SyncEngine (@Observable), Outbox, SyncSnapshot, SyncCache
 │   ├─ Invitations/      InvitationLink (build/parse links, no personal data)
 │   └─ Testing/          InMemoryBackend + SampleData (previews and tests ONLY)
 └─ TogetherListSupabase  SupabaseBackend: wire rows ⇄ domain models, error mapping, realtime

supabase/
 ├─ migrations/           schema, RLS, triggers, SQL functions, realtime publication
 └─ tests/                SQL test suite + a stub of Supabase's auth schema for plain Postgres
```

How the layers fit together:

- **Views** read state from `SyncEngine` and call its methods. They never talk to the network directly.
- **`SyncEngine`** owns the app's state. It talks only to the `BackendService` protocol, so it runs the same against Supabase or the in-memory fake.
- **`SupabaseBackend`** is the only code that knows about tables, columns or the Supabase SDK.

## Data model and rules

| Table | Purpose |
|---|---|
| `profiles` | One row per account (`id` = auth user id, `display_name`, `currency` defaulting to `PLN`). Created by a trigger at sign-up. |
| `lists` | A shopping list with exactly one `owner_id`. |
| `list_members` | Who can access a list. The owner also has a row (`role = 'owner'`). |
| `items` | `id` is generated on the device. Server-owned `created_by/at`, `updated_by/at`, `purchased_by/at` and `version`. `deleted_at` is a permanent tombstone. |
| `invitations` | An invitation to **one** list. Only the SHA-256 hash of the token is stored. It expires (48 h by default, at most 7 days), can be cancelled, and can be used by several people. |
| `connections` | An undirected link between two users (`user_low < user_high`). Created when someone accepts an invitation, between the person accepting and the inviter. |
| `expenses` | One shopping trip: total, currency, who paid, which list (the list name is kept if the list is deleted), optional note. `id` is generated on the device. |
| `expense_shares` | How a trip's total is split: one row per person. |
| `expense_items` | What was bought: a copy of each checked-out item. |
| `settlements` | "A paid B back": money sent between two people to settle up. |

**Ownership and sharing**

- Only the owner can rename or delete a list, create or cancel invitations, add a connection to the list, remove members, or transfer ownership.
- Every member can add, edit, check off and delete items. Members can leave a list. The owner can't leave; they transfer ownership or delete the list instead.
- Connecting with someone does **not** share anything else. Each additional list is shared on its own by its owner (Share → *Your connections*).
- Members of the same list can see each other's display names. Nobody else can.

**Invitations.** The QR code and the link contain only a random 64-hex token,
for example `togetherlist://invite/<token>`. They contain no user IDs, names,
emails or credentials.

- `preview_invitation` reports one of: `valid`, `expired`, `revoked`, `already_member`, `own_invitation` or `invalid`. An expired or cancelled invitation does not reveal the list.
- `accept_invitation` locks the invitation row, inserts the membership and the connection with `ON CONFLICT DO NOTHING`, and counts each use once. Accepting again returns `already_member`, even after the invitation has expired.
- Expiry applies only to the invitation. Membership lasts until someone removes it.

**Disconnecting A from B** removes the connection, removes B from every list A
owns, and removes A from every list B owns. Lists owned by someone else are not
affected, and everyone else on those lists keeps access. The app spells out
these consequences, naming each affected list, before asking for confirmation.

**Deleting an account**

- The owner chooses, for each shared list they own, whether to hand it to a member or delete it.
- Private lists the owner owns are deleted. The screen lists them first.
- Memberships, connections and invitations are removed.
- Items the person added to other people's lists stay, shown as from a "Former member".

**Shopping trips, splitting and settling up**

- **Checkout** (a list's *Check out* bar or menu): pick what you bought, or *Select All*. Items already ticked as "in the basket" are preselected. Then enter the total, who paid, and who shares the cost. `record_purchase` stores the trip, its split and the item copies, and takes the items off the list, in one transaction. It's idempotent, so the offline queue can retry it.
- **Splitting** is equal, in whole cents. Leftover cents go to the people with the lowest user IDs, and the shares always add up to the total. The app shows the same split before saving.
- The payer and everyone in the split must be members of the list. Anyone who paid, created the trip, is in the split, or is on the list can see it. Leaving a list keeps your own trips and debts visible, and the names of the people involved.
- **Balances** are calculated on the device from trips and payments: for each person, what they owe you or you owe them, per currency. *Settle up* records a payment (`record_settlement`). You must be the sender or the receiver, and the other person must be someone you share a list, a trip or a connection with.
- Only the creator or the payer can delete a trip; only the creator can delete a payment. Deleting an account removes that person's shares and payments, and deletes trips nobody is linked to any more.
- **Currency** is an account setting (Settings → Currency, default Polish złoty). It's stored with each trip and payment, so changing it later doesn't alter past amounts. Balances in different currencies are kept apart.

## Sync, offline and conflicts

The engine keeps two things:

- `snapshot`: the last state the server confirmed.
- `outbox`: local changes not yet confirmed by the server.

The UI shows `snapshot` with every outbox change applied on top. That gives
instant local updates, offline use, and changes that survive app restarts.
Both are saved to a per-user JSON file in Application Support, which is deleted
on sign-out.

- **Live updates.** One Realtime channel per user listens to `items`, `lists`, `list_members`, `connections`, `profiles`, `expenses` and `settlements`. An item change is merged straight away; any other change triggers a short, debounced re-fetch. Item fetches only ask for changes since the last server timestamp (with a 30 s overlap). A full fetch happens on first sync and after gaining access to a new list. A pull also runs when the app comes to the foreground and when the network returns.
- **No duplicates.** Item and list IDs are generated on the device and inserts use `ON CONFLICT DO NOTHING`. If a response is lost, the retry is harmless (there's a test for this).
- **Conflicts.** Edits send only the fields that changed. The server applies them in the order they arrive, so the last write wins **per field**. If A renames an item while B changes its quantity, both changes survive. "Purchased" is sent as a true/false value, never as a toggle.
- **Delete wins.** Deletes are tombstones that are never cleared. The server's trigger rejects edits to deleted items and the client's update filters on `deleted_at is null`. Outdated realtime events are ignored using `version`. A deleted item can't come back.
- **Checkout works offline.** The bought items leave the list immediately and the trip appears in History and Balances marked "waiting to sync". It survives app restarts and is sent once. Deleting the list offline afterwards still records the trip first. Payments, deleting a trip and changing the currency need a connection.
- **Clear completed** deletes exactly the items that were completed when you tapped it, by ID. Items someone else checks off afterwards stay.
- **Access revoked while offline.** On reconnect the first write is rejected and the engine pulls. Lists that disappeared are removed locally together with their queued changes. One notice says how many unsynced changes were discarded.
- **Status shown in the UI.** A small pill shows offline, syncing or failed states. Rows waiting to upload show a small cloud icon. Failed writes retry with backoff (2 s, doubling up to 60 s).

## Backend setup

1. **Create a Supabase project** at https://supabase.com/dashboard.
2. **Apply the schema.** Either run each file in `supabase/migrations/` (in filename order) in the dashboard's SQL editor, or use the CLI: `supabase link --project-ref <ref>` then `supabase db push`. The second migration moves the RLS helper functions into a `private` schema the Data API doesn't serve, and indexes the remaining foreign keys.
3. **Set up auth** under Authentication → Providers → Email: enable Email.
   - For quick two-device testing, turn **off** "Confirm email". Otherwise new users must click the email link before signing in. The app shows that message and keeps any pending invitation until they do.
4. **Check Realtime.** The migration adds the tables to the `supabase_realtime` publication. Under Database → Publications, confirm `items`, `lists`, `list_members`, `connections` and `profiles` are listed.
5. **Configure the app:**
   ```sh
   cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig
   ```
   Fill in `SUPABASE_URL` (written as `https:/$()/<ref>.supabase.co`, because `//` starts a comment in xcconfig files) and the **publishable / anon** key from Project Settings → API. **Never** use the `service_role` or secret key. The app needs no privileged secret: every permission is enforced by RLS and the SQL functions.
6. **Signing.** Open `TogetherList.xcodeproj`, pick your team, and change the bundle identifier (currently Xcode's `devplaceholder…` value).

Until step 5 is done, the app shows a "Backend not configured" screen.

**Local stack instead:** run `supabase init` and `supabase start`, copy the migrations
into the generated `supabase/migrations/`, and point `SUPABASE_URL` at
`http:/$()/127.0.0.1:54321`. The Info.plist already allows local networking.

### Camera permission
`NSCameraUsageDescription` is already set. If permission is denied, the scanner
explains why it needs the camera, links to Settings, and offers a "paste link or
code" field. The same field is used on the simulator, which has no camera.

### Invitation links
- **Works out of the box:** the custom scheme `togetherlist://invite/<token>`. It's registered in `Config/Info.plist`, so the iPhone Camera app and Messages can open it.
- **Optional universal links:**
  1. Host `docs/apple-app-site-association` (with your Team ID and bundle ID) at `https://<domain>/.well-known/apple-app-site-association`.
  2. Add the Associated Domains capability with `applinks:<domain>`. This needs a paid developer team.
  3. Set `INVITE_LINK_BASE_URL = https:/$()/<domain>`.

  New QR codes and share links then use `https://<domain>/invite/<token>`. The app accepts both forms either way.

If someone opens an invitation while signed out, the token is saved, survives
sign-up and app restarts, and the preview opens right after sign-in.

## Running on two devices (acceptance scenario)

1. Build and run on device or simulator **A**, and create account A.
2. Run on device or simulator **B** and create account B. Two simulators work: run once, then pick another simulator and run again.
3. **A:** create a list, add items (e.g. "2 kg apples" is parsed into quantity and unit), then tap the share icon. A QR code and link appear.
4. **B:** scan the QR code with the in-app scanner (or the iPhone Camera), or open the link. On a simulator, use *Copy* on A and paste into B's scanner. B sees a preview with the inviter and list name, then taps **Join list**.
5. Both now see the same list. Add or check off items on one device and they appear on the other without refreshing.
6. Force-quit and reopen: the list and the connection are still there. Settings → Connections shows the other person on both devices.
7. A's other lists don't appear for B.
8. **Third user:** sign up C, then scan A's code (multi-use until it expires) or one A creates later.
9. **Offline:** turn on Airplane Mode on B, add, edit and check off items (the pill shows "Offline · N changes saved"), then reconnect. Everything syncs.
10. **Revocation:** test Leave (member), Members → swipe → Remove (owner), and Settings → connection → Disconnect.

## Tests

| Suite | How to run | What it covers |
|---|---|---|
| `supabase/tests/togetherlist_test.sql` | `scripts/test-backend.sh` (uses local Postgres binaries if on PATH, otherwise installs the embedded `pgserver` wheel into `.build/`) | Real SQL against PostgreSQL 16 with Supabase-equivalent roles and default privileges: RLS isolation; private lists stay private; invitation preview, accept, idempotency, use counting, expiry, cancellation and self-invitation; three users on one invitation; owner-only operations; column-level grants; server-owned timestamps and authorship; per-field last-write-wins; delete wins and no resurrection; leave, remove and disconnect semantics (including unrelated lists); ownership transfer; account deletion with transfer; currency setting; recording a purchase (split in whole cents, item copies, items leave the list, idempotent retry); purchase validation (amount, currency, participants on the list) and visibility; settlements (parties only, idempotent, creator-only delete); purchases outliving leaving and list deletion; account deletion cleaning up orphaned purchases; anonymous access denied. |
| `TogetherListKit/Tests/TogetherListCoreTests` | `cd TogetherListKit && swift test`, or ⌘U in Xcode (shared scheme) | 49 Swift Testing tests: outbox coalescing, link parsing, quick-entry parsing, two- and three-device collaboration, realtime delivery, offline queue and reconnect, lost-response no-duplicate, field merge, last-write-wins, delete wins, stale events, clear completed, revoked-while-offline, offline list creation, persistence across relaunch, restore on a new device, amount parsing ("12,50", "1 234,56"…), cent-exact splitting, balances across purchases, payments and currencies, checkout taking items off the list, offline checkout surviving a relaunch and syncing once, settling up, purchases outliving list deletion, delete permissions, currency following the account. These use `InMemoryBackend`, which mirrors the SQL rules. |
| `TogetherListKit/Tests/TogetherListSupabaseTests` | `scripts/test-live.sh` (reads `Config/Secrets.xcconfig`; skipped by a plain `swift test`) | The real `SupabaseBackend` against your project, with two throwaway accounts that are deleted at the end: sign-up and profile trigger, display-name update, idempotent list and item creation, RLS isolation, invitation preview (valid, own, invalid), own-invitation rejection, atomic idempotent accept, only the invited list exposed, connections, Realtime delivery of the other user's item, per-field merge of concurrent edits, delete wins, no resurrection on a retried insert, tombstones in delta sync, member can't rename or delete, revoked invitation, sharing a second list with a connection, recording a purchase (split, item copies, names, idempotent retry, validation), settling up, the currency setting, purchases still visible after disconnecting, disconnect, account deletion. Needs "Confirm email" off. |

You can also try the UI without a backend. Enable the `-UseInMemoryBackend` and
`-DebugSignIn alice@example.com` launch arguments in the scheme. This works in
DEBUG builds only, and the data is seeded fake data that resets on every launch.

### What has actually been verified
- ✅ The SQL suite passes on PostgreSQL 16.2, with a stub standing in for Supabase's `auth.users` and `auth.uid()`.
- ✅ All 49 Swift tests pass, both on macOS (`swift test`) and on the iOS 26.5 simulator (`xcodebuild test`).
- ✅ The app builds with no warnings in our code. The lists screen, the list detail screen in light and dark mode, and the `togetherlist://` link handoff were checked in the simulator using the in-memory backend, as were the History and Balances tabs and the first checkout step. The checkout payment step, the settle-up sheet and the currency picker were not checked on screen.
- ✅ All four migrations applied to a real Supabase project (Postgres 17.11). Supabase's security advisor reports only the 15 intended RPC functions (each checks `auth.uid()` and permissions); the performance advisor reports only "unused index" on new, empty tables.
- ✅ The live suite (`scripts/test-live.sh`) passes against that project: auth, every query and RPC in `SupabaseBackend`, and Realtime delivery between two signed-in users. The first run on a cold project missed one Realtime event while Realtime was starting its replication slot; the client now re-pulls when Realtime confirms Postgres Changes are active.
- ✅ The iOS app built with the real configuration launches to the Welcome screen in the simulator. Sign-up and the rest of the UI against the live backend were not driven by automation.
- ❌ Not run on physical devices: camera scanning, universal links, and two real phones syncing.

## Product decisions and assumptions
- **Sign-in:** email and password, simple to test on several devices. Sign in with Apple can be added through `signInWithIdToken`.
- **Invitations:** multi-use within 48 hours, so one QR code works for a whole household. The owner can cancel one at any time, and creating one requires being online. Membership lasts beyond the invitation.
- **Connections:** only between the person accepting and the inviter. Co-members of a list see each other but aren't automatically connected.
- **Rename:** only the owner can rename a list.
- **Offline support:** creating, renaming and deleting lists and all item edits work offline. Leaving a list, membership changes, invitations, disconnecting and account changes need a connection.
- **Splitting:** always equal between the people you pick. Uneven splits ("I pay for my wine") aren't supported; record those as separate purchases.
- **Checkout** takes the selected items off the list for everyone and keeps a copy in History. Deleting a purchase doesn't put them back.
- **Balances** are pairwise (who owes whom), not simplified across a group; with two or three people that's the same thing.
- **Ordering:** unfinished items appear in the order they were added, then completed items with the most recently checked first.
- **Sign-out:** affects this device only (`scope: .local`) and deletes this device's cached data. The app warns first if there are unsynced changes.

## Known limitations
- Tombstoned items are never purged on the server. A scheduled `delete from items where deleted_at < now() - interval '30 days'` (pg_cron) is a safe follow-up, because clients forget tombstones after 7 days.
- Last-write-wins uses arrival order at the server. Two people editing the same field at the same moment can't merge; the later write replaces the earlier one.
- Deletes in Postgres Changes carry only the primary key, so removals trigger a re-fetch instead of a targeted update. At larger scale, Realtime Broadcast with private channels would be more efficient.
- There are no push notifications. Updates arrive while the app is open, and on next launch or foreground.
- Item fetches page through all of a user's lists. That's fine for household lists, but not designed for thousands of items.
- If a user signs out with unsynced changes, those changes are discarded after the warning.
- A purchase can't be edited after saving; delete it and record it again.
- Amounts in different currencies are never converted; each currency has its own balance.
