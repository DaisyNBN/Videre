# Backend Reassessment Tasks (Updated)

This checklist was reassessed against the current codebase and project docs.

## Reassessment Snapshot

- Completed since last review: scan route flow refactored into service layer (`processScan.ts`).
- Completed since last review: scan create/analyze/detections endpoints are wired and build-clean.
- Completed since last review: user_id/userId requirements removed from active API contracts.
- Completed since last review: schema alignment SQL draft exists (`docs/align-schema-to-docs.sql`).
- Completed: maps route set (`POST /api/maps`, `GET /api/maps`, `GET /api/maps/:id`, `GET /api/maps/:id/graph`, `POST /api/maps/:id/version`).
- Completed: navigation split routes (`POST /api/navigation/routes`, `POST /api/navigation/instructions`, `POST /api/navigation/reroute`) with `/api/navigate` compatibility alias.
- Completed: landmark CRUD + verification endpoints.
- Completed: version endpoint (`GET /api/version`).
- In progress: contributions routes implemented, pending DB table migration (`docs/map-contributions-schema.sql`).
- In progress: request validation/error standardization middleware is active on navigation and hazards routes.
- In progress: automated tests and CI are set up with passing baseline route tests.

## Task 1: Execute and Validate Schema Alignment SQL

Status: In progress.

What is missing:

- `docs/align-schema-to-docs.sql` is drafted but not confirmed as executed in Supabase.
- A rollback-safe smoke test script now exists at `docs/schema-validation-smoke-tests.sql`, but it has not been run yet.

Steps:

1. Run `docs/align-schema-to-docs.sql` in Supabase SQL Editor.
2. Verify enum/table/constraint alignment with `postgres-schema.md`.
3. Run `docs/schema-validation-smoke-tests.sql` after migration and confirm all checks pass.
4. Capture any migration errors and patch SQL for idempotent re-runs.

## Task 2: Normalize Scan Persistence to Match Schema

Status: In progress.

What is missing:

- New writes now use `scan_points` and `scan_landmarks`, but historical rows may still only exist in legacy JSON columns.
- Re-analysis by scan ID still depends on legacy keyframe/depth storage unless analysis is triggered at upload time.
- A one-time backfill script exists at `docs/backfill-scan-json-to-normalized.sql`, but it has not been run yet.

Steps:

1. Run `docs/backfill-scan-json-to-normalized.sql` to migrate legacy JSON rows.
2. Verify reads for legacy scans now come from normalized tables after backfill.
3. Decide a long-term storage path for keyframes/depth samples (legacy columns vs normalized tables).
4. Remove legacy JSON fallback once all clients and historical data are migrated.

## Task 3: Complete Map Routes

Status: Implemented (validation pending).

What is missing:

- End-to-end route behavior has not been API-tested against live Supabase data.
- Version-clone behavior needs smoke testing with real map nodes/edges.

Steps:

1. Run API smoke tests for `POST /api/maps`, `GET /api/maps`, `GET /api/maps/:id`, `GET /api/maps/:id/graph`, and `POST /api/maps/:id/version`.
2. Validate map versioning copies all nodes/edges correctly.
3. Add integration tests for map listing filters and graph retrieval.

## Task 4: Complete Landmark Management and Verification Routes

Status: Implemented (validation pending).

What is missing:

- End-to-end behavior for landmark CRUD and verification aggregation is not API-tested.
- Verification identity strategy is temporary (`verifiedBy` auto-generated when omitted).

Steps:

1. Run API smoke tests for map-scoped landmark CRUD routes.
2. Run API smoke tests for `POST /api/landmarks/:id/verify` and `GET /api/landmarks/:id/verifications`.
3. Validate confidence/status aggregation updates on `landmarks` after verification writes.
4. Replace temporary `verifiedBy` fallback with authenticated identity when auth is introduced.

## Task 5: Expand Navigation API to Planned Surface

Status: Implemented (validation pending).

What is missing:

- End-to-end behavior is not yet smoke-tested with real map graph data.
- Route checkpoint persistence depends on `route_checkpoints` schema availability.

Steps:

1. Run API smoke tests for `/api/navigation/routes`, `/api/navigation/instructions`, and `/api/navigation/reroute`.
2. Verify `/api/navigate` compatibility path continues to return instruction responses.
3. Validate checkpoint persistence and nearest-checkpoint resolution behavior in real DB.

## Task 6: Persist AI Detections to ai_detections and Use Them

Status: Implemented (validation pending).

What is missing:

- Endpoint behavior is not yet smoke-tested against migrated DB state.
- Historical scans still rely on fallback paths if `ai_detections` has no rows.

Steps:

1. Run API smoke tests to confirm detections are persisted per analysis run.
2. Verify bounding box fields are populated when object localization provides geometry.
3. Verify fallback behavior for older scans with no `ai_detections` rows.

## Task 7: Align Payload Docs With Runtime Contract

Status: In progress.

What is missing:

- `scanner-api-payload.md` now uses `imageBase64` and includes size/validation guidance.
- Remaining docs and client integration notes still need a consistency pass.

Steps:

1. Update iOS integration notes and any remaining docs to `imageBase64`.
2. Add optional field handling guidance for tracking quality and checksum metadata.
3. Add server-side payload validation enforcement to match documented limits.

## Task 8: Resolve AI Provider Naming/Implementation Mismatch

Status: In progress.

What is missing:

- Scan service now calls `analyzeImageWithVision`, with backwards-compatible alias retained.
- Overview and architecture docs still reference Gemini Vision for image analysis.

Steps:

1. Finalize canonical provider strategy (Gemini text + Vision image, or hybrid abstraction).
2. Update overview/architecture docs to reflect current implementation.
3. Add explicit startup checks for Vision credentials and error messaging.

## Task 9: Add Collaboration Routes

Status: In progress.

What is missing:

- Endpoints now exist under `/api/maps/:mapId/contributions`.
- `map_contributions` table must be created in Supabase before runtime use.
- Accepted-contribution workflow is currently "submit and optional immediate version creation"; no dedicated review endpoint yet.

Steps:

1. Run `docs/map-contributions-schema.sql` in Supabase.
2. Smoke-test `POST/GET /api/maps/:mapId/contributions`.
3. Add a dedicated review/approval endpoint if moderation workflow needs separation.

## Task 10: Add Version Endpoint and Capability Metadata

Status: Implemented.

What is missing:

- Endpoint contract now has route test coverage.

Steps:

1. Keep version metadata test updated when feature flags change.

## Task 11: Standardize Validation and Error Handling

Status: Implemented (hardening pending).

What is missing:

- Shared zod validation middleware and centralized error handler now exist.
- Navigation, hazards, scans, maps, and landmark verification routes are standardized to validated input + `ApiResponse` output.
- Remaining hardening is mostly around removing duplicated route-level try/catch blocks where central error middleware can own unexpected failures.

Steps:

1. Shift non-domain unexpected failures to centralized error middleware where practical.
2. Keep schema contracts in sync with route/service changes.
3. Ensure all remaining route errors are consistently wrapped in `ApiResponse`.
4. Add regression tests for validation edge cases as routes evolve.

## Task 12: Add Automated Tests and CI Checks

Status: In progress.

What is missing:

- Vitest + Supertest are configured, and route tests now cover navigation, hazards, scans, maps, landmarks, and version metadata.
- GitHub Actions workflow exists to run build + tests.
- Critical scan/map service behaviors still need deeper integration coverage.

Steps:

1. Extend route tests for edge/failure scenarios on scans and maps endpoints.
2. Add service-level tests for scan analysis fallback and map version cloning.
3. Add DB-backed integration smoke tests after schema migration runs.
4. Keep CI workflow as build+test gate and extend coverage threshold checks if needed.

## Revised Execution Order

1. Task 1 and Task 2
2. Task 3 and Task 4
3. Task 6, Task 7, and Task 8
4. Task 5
5. Task 9 and Task 10
6. Task 11 and Task 12

This order keeps schema, persistence, and route behavior aligned before expanding feature surface.
