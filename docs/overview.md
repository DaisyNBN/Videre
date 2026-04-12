# Videre End-to-End Alignment Analysis

Date: 2026-04-12

## Scope

This review compares the implemented backend capabilities in `backend/` with the iOS app implementation in `Videre_ios_app/`.

Primary question assessed:

- Is the app achieving the project goal of sending phone, image, and cane sensor data to backend processing that produces usable indoor maps, landmarks, obstacles, and accessible routes?

## Executive Verdict

The system is **partially aligned**.

What works now:

- The iOS app can capture AR path points, keyframe images, and landmark tags, then upload them to backend scan ingestion.
- The backend can run AI analysis on uploaded keyframes and persist detections/landmarks.

What is not yet end-to-end:

- Uploaded scans are **not automatically converted into maps** in the current iOS flow.
- The app does **not use backend map, route generation, reroute, landmark verification, or contribution APIs**.
- Backend navigation responses are posted to but **not consumed** by the app for spoken/haptic guidance.
- Cane telemetry is not fully parsed/used and is not sent to backend for map or route processing.

Conclusion:

- The current app demonstrates data capture + scan ingestion, but it does **not yet complete the full indoor mapping and accessible routing lifecycle** supported by the backend.

## Goal Check Against Requested Outcome

### Goal A: Phone + image + cane data should go to backend

- Phone trajectory and landmarks: **Yes** (uploaded in scan payload).
- Image keyframes: **Yes** (base64 keyframes uploaded).
- LiDAR depth: **Partial** (only local depth references are sent, not binary depth data).
- Cane sensor stream: **No (end-to-end)** (BLE message parsing does not map core cane fields into runtime state; cane data is not sent to backend).

### Goal B: Backend should process data into maps, landmarks, obstacles, accessible routes

- AI landmarks and detections processing: **Yes (backend capability exists)**.
- Map creation from scan: **Yes (backend capability exists), but not executed by app flow**.
- Landmark verification and contribution workflows: **Yes (backend capability exists), not used by app**.
- Route generation/rerouting from map graph: **Yes (backend capability exists), not used by app**.
- Navigation instruction consumption by app: **No (app posts request but ignores response body)**.

## Capability Matrix (Backend vs iOS)

| Capability | Backend Status | iOS Status | Alignment |
|---|---|---|---|
| Scan ingestion (`POST /api/scans`) | Implemented | Implemented and used | Aligned |
| Auto AI analysis after scan upload | Implemented | Triggered indirectly by scan upload | Aligned |
| Scan processing status (`GET /api/scans/:id/processing`) | Implemented | Not called | Gap |
| Scan detections (`GET /api/scans/:id/detections`) | Implemented | Not called | Gap |
| Map creation (`POST /api/maps`) | Implemented | Not called | Gap |
| Map graph retrieval (`GET /api/maps/:id/graph`) | Implemented | Not called | Gap |
| Navigation route generation (`POST /api/navigation/routes`) | Implemented | Not called | Gap |
| Navigation reroute (`POST /api/navigation/reroute`) | Implemented | Not called | Gap |
| Navigation instruction (`POST /api/navigate` / `/api/navigation/instructions`) | Implemented | Called, but response ignored | Partial gap |
| Landmark CRUD + verify | Implemented | Not called | Gap |
| Map contributions | Implemented (schema migration dependent) | Not called | Gap |
| Hazard report/fetch | Implemented | Methods exist but not used in app flow | Gap |

## Detailed Findings and Discrepancies

### 1) Scan ingestion is connected, but map generation is not chained

- iOS uploads scans to backend (`/api/scans`).
- Backend can create maps from scans via `/api/maps` with `scanId`.
- iOS never calls map creation after upload, so scans do not become room maps in app workflow.

Impact:

- The pipeline stops at "scan stored + AI analyzed" and does not progress to route-ready graph generation.

### 2) Backend offers full indoor mapping APIs that the app does not use

Backend routes exist for:

- Maps, map graph, map versioning
- Landmark CRUD and verification
- Contributions
- Navigation route generation/reroute

iOS usage:

- No map/landmark/contribution API usage was found in the app codebase.

Impact:

- Core indoor mapping/maintenance capabilities are unused from the mobile app.

### 3) Navigation instruction call is wired, but guidance is not consumed

- iOS sends navigate payloads to `/api/navigate`.
- The response is not parsed or surfaced to voice/haptics/UI.
- Current UI label says "Log navigate to console", but the code sends request and discards payload.

Impact:

- Backend-generated guidance is not driving user assistance behavior.

### 4) Route lifecycle is missing in app

- Backend route generation requires `mapId`, `startNodeId`, `endNodeId`.
- iOS does not request routes and uses a fixed `route_id = demo-route`.

Impact:

- Navigation is not actually tied to generated indoor routes.

### 5) Coordinate system mismatch risk in route checkpoint distance math

- Route checkpoints are saved using node `x` and `y` as `lat` and `lng`.
- Nearest checkpoint lookup uses haversine against GPS lat/lng from app.

Impact:

- Indoor AR/world coordinates are treated as geographic coordinates, which can yield invalid distance/nearest-checkpoint behavior.

### 6) Cane sensor integration is incomplete

- BLE manager has published cane state fields (`distanceCm`, `zone`, etc.) and a `CaneData` model exists.
- Parser currently handles only button-style keys (`where`, `what`) and does not map canonical cane telemetry fields.
- Zone alert helper exists but is not called from parsed telemetry.

Impact:

- Cane telemetry influence on backend navigation and app routing is limited/unreliable.

### 7) LiDAR depth evidence is not backend-usable for reconstruction

- App sends `depthUrl` values like `local-depth://...` and does not upload depth blobs.
- Backend receives `depthData` context but current AI analysis path does not use depth to improve landmark/obstacle geometry.

Impact:

- Depth data currently provides little to no practical backend mapping benefit.

### 8) Obstacle data does not become route constraints automatically

- AI obstacles are stored as detections.
- Map graph creation uses points + landmarks, not obstacle detections as graph blockers.
- Route safety depends on caller-provided blocked nodes; iOS does not provide this flow.

Impact:

- "Most accessible" pathing is not yet data-driven by obstacle state in current app/backend interaction.

### 9) Upload reliability edge case: landmarks are required by backend schema

- Backend requires at least one landmark in scan payload (`landmarks.min(1)`).
- iOS allows user to stop and upload without explicitly adding landmarks.

Impact:

- Some scans may fail with 400 despite valid path/keyframe data.

### 10) Large scan payload risk versus backend body size limit

- Backend JSON body limit is 10 MB.
- App sends base64 keyframes in the same request.

Impact:

- Longer scans can exceed request size and fail without chunking/compression strategy.

## Key Evidence References

- iOS scan upload endpoint usage: `Videre_ios_app/Videre_ios_app/Services/SupabaseService.swift:113`
- iOS navigate endpoint usage: `Videre_ios_app/Videre_ios_app/Services/SupabaseService.swift:227`
- Navigate call site from UI: `Videre_ios_app/Videre_ios_app/Views/ContentView.swift:270`
- UI text indicating debug-style navigate action: `Videre_ios_app/Videre_ios_app/Views/ContentView.swift:273`
- Hardcoded route id in app context: `Videre_ios_app/Videre_ios_app/Services/NavigationContextService.swift:18`
- Scan upload success path only checks `success` flag (does not continue to map/route flow): `Videre_ios_app/Videre_ios_app/Services/ScanService.swift:338`
- Backend scan schema requires points and landmarks minimum size 1: `backend/src/schemas/scans.ts:64`, `backend/src/schemas/scans.ts:65`
- Backend maps and navigation advanced endpoints exist: `backend/routes/index.ts:12`, `backend/routes/index.ts:15`, `backend/routes/index.ts:16`, `backend/routes/navigation.ts:65`, `backend/routes/navigation.ts:87`
- Backend map creation from scan exists (but app never calls it): `backend/routes/maps.ts:55`, `backend/routes/maps.ts:56`
- Route generation requires map and node IDs: `backend/src/schemas/navigation.ts:25`, `backend/src/schemas/navigation.ts:26`, `backend/src/schemas/navigation.ts:27`
- Route checkpoint persistence writes x/y into lat/lng fields: `backend/src/services/processNavigation.ts:364`, `backend/src/services/processNavigation.ts:365`
- Nearest-checkpoint distance uses haversine with request GPS location: `backend/src/services/processNavigation.ts:304`
- BLE parser currently keyed only to `where` / `what` commands: `Videre_ios_app/Videre_ios_app/BLE/BLEManager.swift:241`, `Videre_ios_app/Videre_ios_app/BLE/BLEManager.swift:248`
- Cane telemetry model exists but is not wired into parser flow: `Videre_ios_app/Videre_ios_app/BLE/CaneData.swift:10`
- LiDAR depth samples use local URL references: `Videre_ios_app/Videre_ios_app/Services/ScanService.swift:285`
- Backend image analysis accepts depth context but does not convert it into mapping constraints: `backend/src/services/gemini.ts:141`, `backend/src/services/gemini.ts:269`
- Obstacle detections and landmarks are separated in scan processing: `backend/src/services/processScan.ts:549`, `backend/src/services/processScan.ts:556`, `backend/src/services/processScan.ts:563`, `backend/src/services/processScan.ts:564`
- Map graph builder uses points + landmarks as graph inputs: `backend/src/services/processMap.ts:115`, `backend/src/services/processMap.ts:231`

## Overall Assessment

Current maturity by stage:

1. Data capture: **Good (phone + camera + AR landmarks)**
2. Upload + AI detection: **Good**
3. Map creation/versioning: **Backend ready, app not integrated**
4. Landmark verification and contribution loop: **Backend ready, app not integrated**
5. Accessible route generation/rerouting: **Backend ready, app not integrated**
6. End-user assisted navigation using backend responses: **Not complete**

## Priority Fix Plan

### Priority 0 (must-fix for goal alignment)

1. After successful scan upload, call `POST /api/maps` with returned scan ID, then persist selected map ID in app state.
2. Implement route setup flow using `POST /api/navigation/routes` and use returned `routeId` instead of hardcoded demo route.
3. Parse and apply response from `POST /api/navigate` (voice + haptic + UI).
4. Complete BLE telemetry parsing (`distance_cm`, `zone`, `battery`, alert mode fields) and feed it into navigation payload logic.

### Priority 1 (safety/quality)

1. Resolve coordinate mismatch: stop treating AR `x/y` as geographic lat/lng, or introduce a proper indoor-to-geographic transform layer.
2. Ensure obstacle detections can influence route generation (blocked nodes or edge weighting from latest detections/hazards).
3. Add app-side scan guardrails for landmark minimum requirement before upload.

### Priority 2 (robustness and product completeness)

1. Add app flow for verification (`/api/landmarks/:id/verify`) and map contributions.
2. Implement post-upload monitoring (`/api/scans/:id/processing`, `/api/scans/:id/detections`) for user feedback and QA.
3. Introduce payload size management (frame throttling/chunking/compression) to stay within backend limits.

## Final Answer to the Request

- The app is **not yet fully achieving** the intended end-to-end goal with the backend’s existing systems.
- It achieves scan ingestion and basic AI processing trigger.
- It does **not yet operationalize backend indoor mapping, route generation/reroute, verification, contribution, and response-driven navigation**.
- The largest discrepancies are route lifecycle integration, backend response consumption, cane telemetry integration, and coordinate-system correctness.
