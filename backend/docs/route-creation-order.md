# Route Creation Order

This document describes the recommended order to implement API routes for the indoor navigation backend.

The sequence is designed to:

- deliver a working MVP quickly
- keep dependencies clear
- reduce refactoring later

## Phase 0: Foundation Routes

Implement first to confirm app wiring and deployment health.

1. `GET /api/health`

- Returns service status and timestamp.
- Use this for uptime checks and CI smoke tests.

1. `GET /api/version` (optional but useful)

- Returns API version and environment metadata.

Exit criteria:

- server boots reliably
- basic monitoring endpoint works

## Phase 1: Scan Ingestion Routes

Create ingestion routes before AI and maps. Everything depends on scan data.

1. `POST /api/scans`

- Create a new scan upload record.
- Accept `ScanUploadRequest` payload (`userId`, `roomName`, `points`, `landmarks`).

1. `GET /api/scans/:scanId`

- Return scan details and metadata.

1. `GET /api/scans/:scanId/processing`

- Return processing status (`uploaded`, `ai-processing`, `graph-built`, `failed`).

Exit criteria:

- scan data can be saved and fetched
- status endpoint works for asynchronous pipeline flow

## Phase 2: AI Processing Routes

Add Gemini processing once scans are storable and queryable.

1. `POST /api/scans/:scanId/analyze`

- Trigger AI analysis for scan keyframes.

1. `GET /api/scans/:scanId/detections`

- Return `AIObjectDetection[]` with confidence and optional bounding box.

Exit criteria:

- detections can be generated and retrieved
- confidence thresholds can be tested

## Phase 3: Map Graph Routes

Build map routes after scan + AI pipeline is stable.

1. `POST /api/maps`

- Build and persist `RoomMap` from processed scan data.

1. `GET /api/maps`

- List maps with filters (building/room/version).

1. `GET /api/maps/:mapId`

- Return map metadata.

1. `GET /api/maps/:mapId/graph`

- Return graph payload (`MapNode[]`, `MapEdge[]`).

1. `POST /api/maps/:mapId/version`

- Create a new version from approved updates.

Exit criteria:

- map graph can be created, retrieved, and versioned

## Phase 4: Landmark Management and Verification Routes

Implement trust and quality controls once maps exist.

1. `POST /api/maps/:mapId/landmarks`

- Add user landmark.

1. `GET /api/maps/:mapId/landmarks`

- List landmarks for map.

1. `PATCH /api/maps/:mapId/landmarks/:landmarkId`

- Update label/type/position.

1. `DELETE /api/maps/:mapId/landmarks/:landmarkId`

- Remove invalid landmark.

1. `POST /api/landmarks/:landmarkId/verify`

- Submit verification (`verified` or `rejected`).

1. `GET /api/landmarks/:landmarkId/verifications`

- View verification history.

1. `GET /api/maps/:mapId/verification-summary`

- View map confidence summary.

Exit criteria:

- landmark reliability can be improved via community feedback

## Phase 5: Navigation Routes

Add routing after graph quality reaches acceptable level.

1. `POST /api/navigation/routes`

- Compute optimal path using A* from map graph.

1. `POST /api/navigation/instructions`

- Convert path to guidance instructions (audio/haptic friendly).

1. `POST /api/navigation/reroute`

- Recompute route after obstacle/drift updates.

Exit criteria:

- end-to-end route generation works from map graph
- rerouting responds to dynamic changes

## Phase 6: Collaboration Routes

Add contribution workflows last to avoid premature complexity.

1. `POST /api/maps/:mapId/contributions`

- Submit suggested edits.

1. `GET /api/maps/:mapId/contributions`

- Review pending and accepted contributions.

Exit criteria:

- multi-user map improvements can be tracked and reviewed

## Suggested Build Order by File Structure

Recommended route module order:

1. `routes/health.ts`
2. `routes/scans.ts`
3. `routes/ai.ts`
4. `routes/maps.ts`
5. `routes/landmarks.ts`
6. `routes/navigation.ts`
7. `routes/contributions.ts`

Recommended service module order:

1. `services/scanService.ts`
2. `services/geminiService.ts`
3. `services/mapService.ts`
4. `services/verificationService.ts`
5. `services/navigationService.ts`

## Minimal MVP Route Set

If you want the smallest functional milestone first, implement only these routes:

1. `GET /api/health`
2. `POST /api/scans`
3. `GET /api/scans/:scanId`
4. `POST /api/scans/:scanId/analyze`
5. `POST /api/maps`
6. `GET /api/maps/:mapId/graph`
7. `POST /api/navigation/routes`

This MVP set gives you:

- scan upload
- AI enrichment
- graph creation
- route computation
