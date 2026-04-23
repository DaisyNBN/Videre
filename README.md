# Videre

Videre is an experimental indoor-mapping and accessible navigation project (WashU DevFest 2026). It pairs an iOS data-capture app with a TypeScript backend that performs AI-driven image analysis, map construction, and route generation to support voice/haptic navigation.

**Overview**

- **Scope:** capture phone trajectory, images, AR landmarks, and cane telemetry on iOS; upload scans to backend for AI analysis, map/graph creation, and accessible route generation.
- **Executive verdict:** the system is partially aligned — scan ingestion and AI detection work end-to-end, but the iOS app does not yet complete the full map creation → route generation → guidance consumption lifecycle.
- **What works now:** iOS uploads scans and keyframes; backend runs AI analysis and persists detections/landmarks.
- **Open gaps:** the app does not call map creation, route generation, landmark verification, or consume navigation responses; cane telemetry parsing and depth uploads are incomplete; there are coordinate-system and payload-size risks. For details see [docs/overview.md](docs/overview.md).

**Features**

- **Scan ingestion:** POST /api/scans with AR path points, keyframes, and landmarks.
- **AI analysis:** image/keyframe analysis (Cloud Vision / Gemini) with detections persisted as landmarks/obstacles.
- **Map & graph tools:** backend endpoints to create maps from scans and build navigable graphs.
- **Navigation APIs:** generate routes, reroute, and request instruction payloads (UI consumption is currently incomplete in the app).
- **Contributions & verification:** landmark verify and contribution endpoints exist server-side (app integration pending).

**Architecture & Tech Stack**

- **Backend:** Node.js + TypeScript, Express, Zod validation, Supabase client, Google Cloud Vision + Gemini integration, pathfinding/graph libraries. See [backend/](backend/) and [backend/app.ts](backend/app.ts).
- **Mobile client:** Swift / SwiftUI, ARKit / LiDAR capture, BLE for cane telemetry. See [Videre_ios_app/](Videre_ios_app/).
- **Tests & tooling:** backend uses TypeScript, `tsc`, and `vitest` for tests. See `backend/package.json` for scripts.

**Getting started — Backend**

Prerequisites: Node.js (18+ recommended), npm, and (for AI features) Google Cloud CLI or service-account credentials.

1. Configure credentials:
 - For local development use Application Default Credentials (ADC) and set `GEMINI_API_KEY`:

```bash
gcloud auth login
gcloud config set project "$PROJECT_ID"
gcloud auth application-default login
export GOOGLE_CLOUD_PROJECT="$PROJECT_ID"
export GEMINI_API_KEY="your-gemini-api-key"
```

 - Or create a service account and set `GOOGLE_APPLICATION_CREDENTIALS` to the key file (see [backend/docs/google-credentials-setup.md](backend/docs/google-credentials-setup.md)).

2. Install and run the backend:

```bash
cd backend
npm install
# local dev (auto-build + restart):
npm run dev
# or build and run:
npm run build && npm run start
```

1. Health check (default PORT 3000):

```bash
curl -sS http://localhost:3000/api/health
```

Notes:

- The backend accepts JSON bodies up to 10 MB by default (`express.json({ limit: '10mb' })`). Large scan payloads should be chunked or compressed.
- Environment variables that matter include `GEMINI_API_KEY`, `GOOGLE_APPLICATION_CREDENTIALS` (or ADC), `GOOGLE_CLOUD_PROJECT`, and optionally `FRONTEND_URL`.

**Getting started — iOS app**

Prerequisites: Xcode (use latest stable), a physical iOS device with ARKit/LiDAR support for realistic testing.

1. Open the Xcode project in [Videre_ios_app/](Videre_ios_app/) and select the appropriate target device.
2. Configure API keys and endpoints by editing `Videre_ios_app/Videre_ios_app/Config/Secrets.swift` — set `geminiAPIKey`, `googleMapsKey`, and `apiURL` to point at your backend (for local backend use `http://localhost:3000/` or a tunnel URL).
3. Build and run on device. The app needs Camera/AR permissions and Bluetooth permission for cane telemetry.

Security note: do not commit API keys or credential files. Use environment-managed secrets or CI secrets for build servers.

**Known issues & recommended next steps (short roadmap)**

- **Priority 0:** After scan upload, chain a `POST /api/maps` call to automatically create a map from the scan; persist the selected `mapId` in the app. Implement route setup using `POST /api/navigation/routes` and use returned `routeId` instead of a hardcoded demo route. Parse and surface `POST /api/navigate` responses to voice/haptic UI. Complete BLE telemetry parsing and include cane state in navigation payloads.
- **Priority 1:** Fix coordinate-system mismatch (do not treat AR `x/y` as GPS lat/lng without transform). Allow obstacles/detections to influence route generation (blocked nodes/edge weights). Add client-side guardrails so scans include at least one landmark before upload.
- **Priority 2:** Add contribution/verification flows in the app, implement post-upload processing monitoring (`GET /api/scans/:id/processing`), and add payload size management (frame throttling or chunking).

**Where to read more**

- Alignment analysis & evidence: [docs/overview.md](docs/overview.md)
- Google credential and Gemini setup: [backend/docs/google-credentials-setup.md](backend/docs/google-credentials-setup.md)

**Contributing & running tests**

- Backend tests: from `backend/` run `npm test`.
- Please open issues or pull requests for feature work; include small, focused changes and add tests for backend logic when possible.

---
2026 WashU DevFest — Videre
