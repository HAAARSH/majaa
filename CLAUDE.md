# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**MAJAA Sales** — a Flutter B2B sales order management app for Madhav & Jagannath Associates. Supports iOS, Android, and Web. Backend is Supabase (PostgreSQL + Auth + Realtime).

## Companion Desktop App

A companion desktop app lives in a separate repository: <https://github.com/HAAARSH/majaa_desktop>. Both repos are owned by the `HAAARSH` GitHub account and share the same Supabase backend (so schema changes, RLS policies, and `team_id` filters must stay consistent across both).

When you need to read or edit the desktop app, clone it as a sibling directory:

```bash
git clone https://github.com/HAAARSH/majaa_desktop.git ../majaa_desktop
```

Cross-repo work that touches Supabase tables, models, or auth flows should be reviewed against the desktop repo to avoid drift.

## Commands

### Flutter (primary app)

```bash
# Install dependencies
flutter pub get

# Run (env vars required)
flutter run --dart-define-from-file=env.json

# Build
flutter build apk --release
flutter build ios --release

# Test / lint
flutter test
flutter analyze
flutter format lib/
```

The VS Code launch config already passes `--dart-define-from-file env.json` — use that when debugging in IDE.

### Web (React dashboard component)

```bash
npm run dev        # dev server on :3000
npm run build      # production build
npm run lint       # TypeScript type-check
```

## Architecture

### Models (`lib/models/`)

Dedicated model files with `fromJson`/`toJson`. Barrel file `models.dart` re-exports all models. Key models: `product_model`, `customer_model`, `order_model`, `beat_model`, `visit_log_model`, `collection_model`, `app_user_model`, `bill_extraction_model`.

### Service Layer (`lib/services/`)

All backend logic lives here. Services are **not** InheritedWidget/Provider — they are used directly (static or singleton).

| Service | Role |
|---|---|
| `supabase_service.dart` | All CRUD — the central data layer |
| `auth_service.dart` | Auth + `currentTeam` global (defaults `'JA'`) |
| `cart_service.dart` | In-memory cart state |
| `offline_service.dart` | Hive queue + auto-sync on reconnect |
| `pdf_service.dart` / `pdf_generator.dart` | Report generation |
| `google_drive_service.dart` | Export/import via Google Drive |
| `google_drive_auth_service.dart` | Google Drive OAuth |
| `drive_sync_service.dart` | Drive sync logic |
| `gemini_ocr_service.dart` | OCR via Gemini API |
| `bill_extraction_service.dart` | Bill data extraction |
| `csv_reconciliation_service.dart` | CSV reconciliation |
| `session_service.dart` | Session management |
| `pin_service.dart` | PIN-based auth |
| `hero_cache_service.dart` | Hero image caching |
| `update_service.dart` | In-app update management |
| `service_account_auth.dart` | Service account auth |

### Multi-Team Pattern

- `AuthService.currentTeam` (global `String`) gates which team's data is shown.
- Hive cache is namespaced: `cache_{teamId}`.
- All Supabase queries filter by `team_id`. When adding new queries, always include this filter.

### Offline-First Pattern

`OfflineService` queues operations in Hive when offline and replays them when `connectivity_plus` detects reconnection. New order-mutation code should go through this service rather than calling Supabase directly.

### Presentation Layer (`lib/presentation/`)

One folder per screen, each typically containing a `*_screen.dart` and widget files. Navigation is handled through named routes defined in `lib/routes/app_routes.dart`.

### Responsive Sizing

Uses the `sizer` package: `50.w` = 50% of screen width, `20.h` = 20% of screen height. Use this instead of hardcoded pixel values.

## Environment

Secrets are in `env.json` (git-ignored). Required keys:
- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`

Optional: `GEMINI_API_KEY`, `GOOGLE_WEB_CLIENT_ID`, etc.

Access in Dart via `const String.fromEnvironment('SUPABASE_URL')` (injected by `--dart-define-from-file`).

## Key Patterns

- **Models** are defined inside `supabase_service.dart` with `fromJson`/`toJson`. Add new models there.
- **Centralized imports**: `lib/core/app_export.dart` re-exports common packages — prefer importing from here in screens/widgets.
- **Theme**: Material Design 3 via `lib/theme/app_theme.dart`. Use `Theme.of(context)` tokens rather than hardcoded colors.
