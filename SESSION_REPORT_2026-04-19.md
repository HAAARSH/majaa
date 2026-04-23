# MAJAA Sales — Session Report (2026-04-19)

## 1. Artifacts

| | |
|---|---|
| **Android APK** | `build/app/outputs/flutter-apk/app-release.apk` (70.6 MB) |
| **App version** | `1.2.4+8` |
| **Commit shipped** | `b8befa7` on `main` (16 files, +1019 / −218) |
| **Flutter analyze** | **0 errors** (175 info/warnings — all pre-existing) |
| **Uncommitted** | 1 bug fix in `lib/services/supabase_service.dart` (settle `team_id` on `customer_team_profiles`) |

## 2. Required SQL (run in Supabase BEFORE new APK logs in)

```sql
-- user-version telemetry
ALTER TABLE app_users
  ADD COLUMN IF NOT EXISTS app_version TEXT,
  ADD COLUMN IF NOT EXISTS app_version_at TIMESTAMPTZ;

-- ordering-beat override (Dobhal & Navi style customer splits)
ALTER TABLE customer_team_profiles
  ADD COLUMN IF NOT EXISTS order_beat_id_ja TEXT,
  ADD COLUMN IF NOT EXISTS order_beat_name_ja TEXT,
  ADD COLUMN IF NOT EXISTS order_beat_id_ma TEXT,
  ADD COLUMN IF NOT EXISTS order_beat_name_ma TEXT;
```

Without these: logins still work (errors swallowed), but version chips show "v?" and ordering-beat overrides can't be saved.

## 3. Supabase `app_settings` update (after Drive upload)

If you replace the existing Drive file (same URL):
```sql
UPDATE app_settings SET latest_version = '1.2.4' WHERE id = 1;
```

If you upload as new file (new ID):
```sql
UPDATE app_settings
SET latest_version   = '1.2.4',
    apk_download_url = 'https://drive.google.com/file/d/<NEW_FILE_ID>/view?usp=sharing',
    mandatory_update = true
WHERE id = 1;
```

---

## 4. Features shipped in v1.2.4

### 4.1 Ordering-beat override (new data model + UI)

Real-world case: "Dobhal & Navi" pays bills at office on Dharampur 2nd route, but receives stock at shop on Panditvari route.

**Schema:** 4 new nullable columns on `customer_team_profiles` — `order_beat_id_ja`, `order_beat_name_ja`, `order_beat_id_ma`, `order_beat_name_ma`.

**Admin UI** (`admin_customers_tab.dart` edit dialog) — per team JA/MA:
- Checkbox `[ ] Different ordering beat for JA` / `MA`
- When checked: ordering-beat dropdown unlocks
- When unchecked: override cleared to null on save

**Model helpers** (`customer_model.dart`):
- `orderBeatIdOverrideForTeam(team)` — returns override or null
- `effectiveOrderBeatIdForTeam(team)` — override, or primary if null
- `hasOrderBeatOverrideForTeam(team)` — boolean

**Filter logic:**
| Screen / feature | Filter used |
|---|---|
| Customer list for beat X (order flow) | primary == X **OR** override == X |
| Today's beat customer count on dashboard | primary == X **OR** override == X |
| OOB sheet customer search | both primary and override across both teams |
| Outstanding report / Next-Day-Due | **primary only** (ACMAST billing address) |
| Settle flow | customer_id only (no beat filter) |

**ACMAST sync safety:** sync updates `beat_id_*` / `beat_name_*` only. **Never touches `order_beat_id_*`** — manual overrides survive every CSV re-import.

### 4.2 Order submit uses rep's selected beat (not customer's primary)

`order_creation_screen.dart::_submitOrder` — priority flipped:
1. `_selectedBeat.beatName` (cart's beat = rep's working route)  
2. customer's primary beat name (fallback for edit flows)  
3. `editingOriginalBeatName` (last-resort fallback)

Why: pending orders bucket to the rep's actual route, so "Panditvari" rep picks up Dobhal's order next day, not "Dharampur 2nd" rep.

### 4.3 Cross-team billing CSV export

**Problem:** JA rep sold SHADANI (MA brand) → JA CSV included SHADANI → JA billing software rejected (no SHADANI in JA product master).

**Fix** (`admin_orders_tab.dart::_downloadCsv` + `_buildCsv`):
- Cross-team fetch pulls other-team orders containing selected-team products
- `_buildCsv` filters each order's line items to only products owned by the selected team
- Orders with zero remaining lines are skipped

**Beat picker:** now shows ALL beats from both same-team and cross-team orders. Subtitle: `"5 orders · 4 JA + 1 cross-team from MA"`. Unticking a beat excludes both sets.

**Pre-export summary dialog** (new, only fires when cross-team pickups exist):
- Green check: "X orders booked under [team]"
- Orange arrows: "Y cross-team orders from [other] reps with [team] products"
- Italic note: "Line items that don't belong to [team] will be skipped"
- Buttons: Cancel / Export CSV

Works for v1.2.0-era orders too (data-only change, driven by `product_id`).

### 4.4 Sunday-shift + IST helper for collection tab

**New:** `lib/core/time_utils.dart` — `TimeUtils.nowIst()`, `todayIstStr()`, `todayIstWeekday()`. All compute via `DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30))`, immune to device-TZ drift.

**In `beat_selection_screen.dart`:**
- New `_effectiveToday` getter — `TimeUtils.nowIst()` except on Sunday → Monday
- `_isBeatToday`, `_loadData.todayStr`, `_loadTabData.today` — use `_effectiveToday`
- NDD calc stays on raw `TimeUtils.nowIst()` → spec preserved: Sat→Mon, Sun→Mon, Mon→Tue

### 4.5 Collection tab: unified Share + Print buttons

Before: two duplicate button pairs (one for outstanding, one for overlay).

Now: single `_buildCollectionActionsRow()` — one Share + one Print.
- `_todayCollections.isEmpty` → outstanding report
- Non-empty → overlay PDF (cash/UPI/cheque against bill numbers)

### 4.6 User-version telemetry

**New columns** (`app_users.app_version`, `app_users.app_version_at`).

**Write** (`auth_service.dart::_reportAppVersion`): fire-and-forget after successful login. Uses `package_info_plus`. Timestamp is UTC. Errors swallowed.

**Read + display** (`admin_users_tab.dart`):
- Fetches `app_settings.latest_version` on tab load
- User card shows version chip:
  - **Green ✓ v1.2.4** = on latest
  - **Orange ⚠ v1.2.0** = behind
  - **Grey v?** = never reported

### 4.7 OOB sheet: customer search

**`beat_selection_screen.dart::_OutOfBeatSheetContent`:**
- Search hint: "Search customer…"
- Search queries tokenize across `name / phone / address`, scoped to customers on rep's allowed beats (primary OR ordering override)
- Tap customer → navigates directly to `customer_detail` with `isOutOfBeat: true` and the resolved beat
- If no query: falls back to existing beat list (minus today's beats)
- `_resolveCustomerBeat` prefers override over primary so OOB-tapped customers land under the beat the rep is working

### 4.8 OOB beat-pick: tight customer list

Picking a beat from OOB sheet now shows ONLY that beat's customers (mirrors today-beat behavior). Before: showed all team customers. Change in `customer_list_screen.dart::_loadCustomers`.

### 4.9 Super_admin: team-scope pickers

`admin_shared_widgets.dart::TeamFilterChips` — new widget (JA / MA / All).

Added to:
- `admin_dashboard_tab` — analytics re-fetch on change; drill-through intent propagates team
- `admin_beats_tab` — beats list re-fetches per team
- `admin_bill_verification_tab` — Pending/Returned/Delivered-unverified queries honor All
- `admin_products_tab` — All = two fetches merged (JA + MA)
- `admin_visits_tab` — All drops team filter
- `admin_error_management_tab` — new `sync_unfinished_eod` label + color

Service sentinel pattern (`supabase_service.dart`): `getBeats` / `getVisitLogs` / `getSalesAnalytics` accept optional `teamId`. Omitted → `currentTeam`. Explicit `null` → all teams. Cache keys include team scope.

All team pickers default to **"All"** on open.

### 4.10 Persistent offline / sync banner

**`main.dart::_PendingSyncBanner`** — global Overlay, listens to `OfflineService.syncStatus` + `pendingCountNotifier`:
- **Blue**: "Syncing N items..."
- **Orange**: "N pending sync — tap to retry"
- **Red**: "Sync failed — tap to retry"

**`offline_service.dart`:**
- New `pendingCountNotifier` (ValueNotifier<int>)
- New `forceSyncNow()` (banner tap handler)
- Hourly timer now calls `syncAll()` if anything is pending
- **End-of-day 10-min polling** — at 9 PM local, if pending > 0, fires a `sync_unfinished_eod` row into `app_error_logs` (deduped per calendar day). Super_admin sees the alert on the Errors tab next morning.

### 4.11 Drive large-file download fix

Google changed their virus-scan interstitial. Old retry hit `drive.google.com/uc?confirm=...` (dead path); new form posts to `drive.usercontent.google.com/download`.

`update_service.dart::downloadAndInstall` now:
- Parses the form `action` attribute and all hidden inputs dynamically
- Falls back to the known usercontent endpoint if action parsing fails
- Works for any future Drive UI change that keeps the form pattern

Also: new **"Download in Browser"** button on the update error dialog. Uses `url_launcher` to open the Drive URL in the device browser as a manual fallback.

### 4.12 Sales_rep UX

| Issue | Fix |
|---|---|
| R1 — Cart silently cleared when rep taps different customer | Blocking dialog listing items + old customer name; "Cancel" / "Clear & Continue" |
| R2 — Qty dialog accepts empty / 0 → silent cart damage | `StatefulBuilder` with inline errorText; rejects empty/zero/negative |
| R3 — Manual qty ignored pack-size (stepSize) | Same dialog — rejects non-multiples with error |
| R7 — Offline submit looked identical to online | `isOffline` param on success dialog → "Order Saved!" title + orange cloud-off pill |
| R8 — No auto-visit log on order | `logVisit` reason='order_placed' fires after both online + offline submit; skipped on edit |
| R11 — Silent sync failures | Persistent banner + retry + EoD alert (see 4.10) |
| R13 — Stock color thresholds confusing | Badge shows numeric count; red ONLY when `stockQty == 0` |
| R20 — Order ID hard to read | 16px, primary color, tappable → clipboard copy + "Order ID copied" toast |

### 4.13 Brand_rep UX

| Item | Fix |
|---|---|
| OOB FAB hidden for brand_rep | **Restored** — Sunday / walk-in unblocked |
| Customer list pinning | "★ Your Brand" chip for customers with brand-history (both in-app orders AND ITTR `customer_billed_items`); coexists with concurrent session's brand-tab split |
| Brand-history query scale | Chunked at 100-item batches on all 3 `inFilter` calls (product_id, order_id, item_name) — stays under PostgREST ~8KB cap |
| `searchProducts` scope | Accepts `allowedBrands` — scopes search across teams by category when brand_rep |
| Admin user dialog | FilterChip grid when role=brand_rep; pre-loads existing grants; save resets + upserts. Helper text points to Brand Access tab for cross-team. |
| Checkout brand-strip | Blocks with confirmation dialog listing items being removed — replaces old silent strip |

### 4.14 Sales_rep / brand_rep false alarms verified safe

- R4 (empty qty swallowed) — subsumed by R2
- R5 (search clears on scroll) — verified survives rebuilds
- R6 (submit double-tap) — already had `_isSubmitting` guard
- R9 (no min order) — skipped per user "no minimum"
- R10 (FAB hidden when empty) — correct behavior
- R12 (keyboard not closed) — fixed by R2 dialog pop
- R14 (clear cart on Done) — intentional; cart already submitted
- R15 (phone dialog once per session) — intentional
- R16 (success dialog no back button) — intentional

---

## 5. Uncommitted fix (session wrap)

Late in session, a runtime error screenshot surfaced:
```
PostgrestException 42703 — column customer_team_profiles.team_id does not exist
```

**Root cause:** `supabase_service.dart:2244` settle flow filtered `customer_team_profiles` by `.eq('team_id', team)`. That table has **no `team_id` column** — team lives in column names (`outstanding_ja` vs `outstanding_ma`). The row is uniquely keyed by `customer_id`.

**Fix:** Removed both `.eq('team_id', team)` filters in the settle path. Pre-existing bug; not introduced this session.

**Status:** edited locally, flutter analyze clean (0 errors). **Not yet committed or included in v1.2.4 APK** — awaiting your decision whether to ship as v1.2.5 immediately or bundle with next batch.

---

## 6. Files touched today

```
NEW:
  lib/core/time_utils.dart

MODIFIED:
  lib/main.dart
  lib/models/app_user_model.dart
  lib/models/customer_model.dart
  lib/presentation/admin_panel_screen/widgets/admin_beats_tab.dart
  lib/presentation/admin_panel_screen/widgets/admin_bill_verification_tab.dart
  lib/presentation/admin_panel_screen/widgets/admin_customers_tab.dart
  lib/presentation/admin_panel_screen/widgets/admin_dashboard_tab.dart
  lib/presentation/admin_panel_screen/widgets/admin_error_management_tab.dart
  lib/presentation/admin_panel_screen/widgets/admin_orders_tab.dart
  lib/presentation/admin_panel_screen/widgets/admin_products_tab.dart
  lib/presentation/admin_panel_screen/widgets/admin_shared_widgets.dart
  lib/presentation/admin_panel_screen/widgets/admin_users_tab.dart
  lib/presentation/admin_panel_screen/widgets/admin_visits_tab.dart
  lib/presentation/beat_selection_screen/beat_selection_screen.dart
  lib/presentation/customer_list_screen/customer_list_screen.dart
  lib/presentation/customer_detail_screen/customer_detail_screen.dart
  lib/presentation/order_creation_screen/order_creation_screen.dart
  lib/presentation/products_screen/products_screen.dart
  lib/presentation/products_screen/widgets/product_list_item_widget.dart
  lib/services/auth_service.dart
  lib/services/drive_sync_service.dart
  lib/services/offline_service.dart
  lib/services/supabase_service.dart         [includes settle team_id fix — uncommitted]
  lib/services/update_service.dart
  pubspec.yaml                               [1.2.0+4 → 1.2.4+8]
```

## 7. Desktop app (majaa_desktop) — NOT YET PORTED

Today's Android admin changes that still need porting to `majaa_desktop`:

| Desktop page | Needs |
|---|---|
| `dashboard_page.dart` | TeamFilterChips (missing) |
| `orders_page.dart` | Has team filter. Needs: cross-team export CSV split, team-wise beat picker, pre-export summary dialog |
| `products_page.dart` | Has team filter (already) |
| `customers_page.dart` | Ordering-beat override checkbox + dropdown |
| `beats_page.dart` | Has team filter (already) |
| `visits_page.dart` | Has team filter (already) |
| `users_page.dart` | Version chip, brand access FilterChip grid |
| `errors_page.dart` | `sync_unfinished_eod` label + color |

Missing tabs entirely (Android has, desktop doesn't):
- Brand Access
- Bill Verification
- Beat Orders

Deferred to next session.

---

## 8. Known caveats / deferred

- **Debug keystore** — release APK still signed with debug keystore (TODO in `android/app/build.gradle.kts` never resolved). Auto-install fails if phone's prior APK was from a different keystore. Fresh reps on v1.2.0 from this same machine will auto-update fine.
- **Native splash** — still shows Flutter F logo for ~3-5s on cold launch. Needs `flutter_native_splash` package + brand PNG. Flagged since prior sessions.
- **v1.2.0 → v1.2.4 auto-update** — v1.2.0 has the OLD Drive retry logic. Might hit the same `drive.usercontent` interstitial and fail. Mitigation: new "Download in Browser" button in v1.2.1+ error dialog, but v1.2.0 users don't have that. Fallback: manual install v1.2.4 once via browser/ADB; future upgrades work.
- **Pre-existing 175 info/warn** — unused imports / deprecated `withOpacity` calls. Left untouched per scope.
