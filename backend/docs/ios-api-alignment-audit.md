# iOS to Backend API Alignment Audit

Date: 2026-04-12

## Scope

Reviewed Swift networking calls in the iOS app and compared request targets/payloads against Express routes and Zod schemas in `backend/`.

## Backend Endpoints Cross-Checked

- `POST /api/scans` (`backend/routes/scans.ts`, `backend/src/schemas/scans.ts`)
- `POST /api/navigate` (`backend/routes/navigation.ts`, `backend/src/schemas/navigation.ts`)
- `POST /api/hazards` and `GET /api/hazards/nearby` (`backend/routes/hazards.ts`, `backend/src/schemas/hazards.ts`)

## Changes Applied

1. Backend-bound requests now use `Secrets.apiURL` (normalized to include `/api`) instead of localhost log URL.
2. `ingest-scan` calls now post to `POST /api/scans`.
3. Hazard APIs now target backend routes:
   - `reportHazard` -> `POST /api/hazards`
   - `fetchHazards` -> `GET /api/hazards/nearby?lat=...&lng=...&radius=...`
4. Navigate API now posts to `POST /api/navigate` via configured `apiURL`.
5. Scan payload aligned with backend scan schema:
   - Added `keyframes[].imageBase64` in iOS payload.
   - Normalized landmark `type` values to backend enum-compatible values.
   - Normalized ARKit landmark `source` to backend-compatible values.
6. iOS networking is now API-only:
   - Removed direct Supabase REST/function/storage HTTP usage.
   - Scan keyframes are sent inline in `POST /api/scans` payload.
   - Depth samples now use local depth references instead of storage uploads.
   - Supabase credentials were removed from iOS `Secrets`.

## Remaining Risk / Follow-up

1. `scanCreateBodySchema` requires `points` and `landmarks` arrays with at least one item each (`min(1)`).
   - If a very short scan yields no landmarks, backend will still reject the request with 400.
2. There is no `POST /api/sessions` route in the backend today.
   - Session history upload/read should remain disabled on iOS until a backend route is added.

## Updated iOS Files

- `Videre_ios_app/Videre_ios_app/Services/SupabaseService.swift`
- `Videre_ios_app/Videre_ios_app/Services/ScanService.swift`
- `Videre_ios_app/Videre_ios_app/Services/ScanPayLoad.swift`
- `Videre_ios_app/Videre_ios_app/Services/ARMeshLandmarkSampler.swift`
- `Videre_ios_app/Videre_ios_app/Config/Constants.swift`
- `Videre_ios_app/Videre_ios_app/Views/ContentView.swift`
- `Videre_ios_app/Videre_ios_app/Config/Secrets.swift`
