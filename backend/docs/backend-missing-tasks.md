# Backend Missing Tasks and Implementation Steps

This checklist compares the current backend against the overview, route plan, payload contract, and schema proposal.

## Current Status Summary

- Implemented: scan ingest routes, scan analysis trigger, detections route, hazard routes, health route.
- Partially implemented: navigation (single endpoint, not full planned route set).
- Missing: maps, landmark management, verification, collaboration, full schema alignment, and full contract consistency.

## Task 1: Implement Database Migrations for the Proposed Schema

Status: Not done.

What is missing:

- The schema in docs is not fully represented as migration files.
- Core graph, verification, and AI detection tables are not fully operational as a normalized model.

Steps:

1. Create enum migrations for landmark_type, landmark_source, node_type, and verification_status.
2. Create table migrations for room_maps, map_nodes, map_edges, landmarks, landmark_verifications, scans, scan_points, scan_landmarks, ai_detections, and hazard_reports.
3. Add constraints and indexes for keys, confidence bounds, and high-traffic query columns.
4. Apply migrations locally and run insert/select smoke tests for each table group.

## Task 2: Finish Map Routes

Status: Not done.

What is missing:

- The maps route module is empty.
- Phase 3 map endpoints from the route plan are not available.

Steps:

1. Implement POST /api/maps to build and persist a map from processed scan output.
2. Implement GET /api/maps to list maps by room and version filters.
3. Implement GET /api/maps/:mapId to fetch map metadata.
4. Implement GET /api/maps/:mapId/graph to return nodes and edges.
5. Implement POST /api/maps/:mapId/version to create a new map version.

## Task 3: Finish Landmark Management Routes

Status: Not done.

What is missing:

- The landmarks route module is empty.
- Landmark CRUD and map-level edits are not available.

Steps:

1. Implement POST /api/maps/:mapId/landmarks to create landmarks.
2. Implement GET /api/maps/:mapId/landmarks to list landmarks.
3. Implement PATCH /api/maps/:mapId/landmarks/:landmarkId to update label, type, or position.
4. Implement DELETE /api/maps/:mapId/landmarks/:landmarkId to remove invalid landmarks.

## Task 4: Add Verification Routes and Confidence Workflow

Status: Not done.

What is missing:

- Verification endpoints in the route plan are not implemented.
- Confidence/review lifecycle is not persisted.

Steps:

1. Implement POST /api/landmarks/:landmarkId/verify to submit verification actions.
2. Implement GET /api/landmarks/:landmarkId/verifications for audit history.
3. Implement GET /api/maps/:mapId/verification-summary for reliability metrics.
4. Update landmark status and confidence using aggregated verification outcomes.

## Task 5: Complete Planned Navigation API Surface

Status: Partial.

What is missing:

- Planned navigation routes are not split by responsibility.
- Current navigation does not fully follow graph-based route generation flow in docs.

Steps:

1. Implement POST /api/navigation/routes for graph-based A* route generation.
2. Implement POST /api/navigation/instructions for turn-by-turn instruction output.
3. Implement POST /api/navigation/reroute for dynamic obstacle/drift updates.
4. Keep current endpoint as a temporary compatibility alias until clients migrate.

## Task 6: Persist AI Detections in Dedicated Storage

Status: Partial.

What is missing:

- AI detections are merged into scan landmarks but not persisted as dedicated ai_detections rows.
- Detections endpoint cannot consistently return bounding boxes from storage.

Steps:

1. Insert per-keyframe detections into ai_detections during analysis.
2. Save confidence and optional bounding box fields when available.
3. Update GET /api/scans/:scanId/detections to read from ai_detections first.
4. Keep a fallback path for legacy scans that only contain landmarks JSON.

## Task 7: Align Scan Payload Contract Across Docs and Code

Status: Inconsistent.

What is missing:

- Docs still show keyframe imageUrl while backend expects imageBase64.
- Advanced payload fields in docs are not fully validated server-side.

Steps:

1. Update scanner payload docs and examples to imageBase64.
2. Update mobile payload spec and uploader examples to match server contract.
3. Add validation for base64 format, payload size, and timestamp consistency.
4. Add optional handling for arTrackingQuality, coordinateSystem, sequenceNumber, checksum, and idempotencyKey.

## Task 8: Resolve AI Provider Naming and Architecture Consistency

Status: Inconsistent.

What is missing:

- Documentation says Gemini Vision, while implementation now uses Google Cloud Vision in image analysis.
- Function names still imply Gemini in places where Vision is used.

Steps:

1. Decide the canonical image-analysis provider strategy.
2. Rename service and function names to match the chosen provider.
3. Update overview and architecture docs to reflect the true backend implementation.
4. Add startup checks for required provider credentials.

## Task 9: Add Collaboration Routes

Status: Not done.

What is missing:

- Contribution workflows from Phase 6 are not implemented.

Steps:

1. Implement POST /api/maps/:mapId/contributions for user-submitted edits.
2. Implement GET /api/maps/:mapId/contributions for pending and accepted reviews.
3. Link accepted contributions to map version creation.

## Task 10: Add Version Route and Capability Metadata

Status: Not done.

What is missing:

- GET /api/version endpoint from the route plan is absent.

Steps:

1. Add GET /api/version in the root router.
2. Return app version, environment, and build metadata.
3. Include feature flags for scan analysis, navigation, and map features.

## Task 11: Add Request Validation Layer and Error Standardization

Status: Partial.

What is missing:

- Validation is manual and repeated across routes.
- Error responses are not fully standardized.

Steps:

1. Add zod schemas for all route inputs and outputs.
2. Replace manual validation blocks with shared schema parsing.
3. Standardize all route errors to ApiResponse format.
4. Add centralized Express error middleware.

## Task 12: Add Basic Automated Test Coverage

Status: Not done.

What is missing:

- No baseline route and service tests for critical flows.

Steps:

1. Add route tests for scans create, analyze, and detections.
2. Add service tests for navigation fallback and hazard handling.
3. Add DB integration smoke tests for migrated schema.
4. Add build and test steps to CI.

## Recommended Execution Order

1. Task 1
2. Task 11
3. Task 2 and Task 3
4. Task 4
5. Task 6 and Task 8
6. Task 5
7. Task 9
8. Task 10 and Task 12

This order minimizes rework and keeps API behavior aligned with the project documents.
