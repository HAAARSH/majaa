# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**MAJAA Sales** — a Flutter B2B sales order management app for Madhav & Jagannath Associates. Supports iOS, Android, and Web. Backend is Supabase (PostgreSQL + Auth + Realtime).

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

### Service Layer (`lib/services/`)

All backend logic lives here. Services are **not** InheritedWidget/Provider — they are used directly (static or singleton).

| Service | Role |
|---|---|
| `supabase_service.dart` (~28KB) | All CRUD — the central data layer |
| `auth_service.dart` | Auth + `currentTeam` global (defaults `'JA'`) |
| `cart_service.dart` | In-memory cart state |
| `offline_service.dart` | Hive queue + auto-sync on reconnect |
| `pdf_service.dart` / `pdf_generator.dart` | Report generation |
| `google_drive_service.dart` | Export/import via Google Drive |
| `update_service.dart` | In-app update management |

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
