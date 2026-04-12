# Indoor Navigation Execution Plan (Using Existing Stored Data)

## Objective

Enable users to navigate inside a building using data already captured and stored in current tables.

## Success Criteria

- Route generation succeeds for at least 95% of pilot requests on existing maps.
- Navigation instruction responses remain under 2 seconds in normal conditions.
- Reroute works when nodes are blocked by hazards or temporary obstacles.
- Scan and navigation pipelines remain stable even if AI services are limited.

## Existing Assets We Will Use

### Tables

- Scan and detections: `scans`, `scan_points`, `scan_landmarks`, `ai_detections`
- Indoor map graph: `room_maps`, `map_nodes`, `map_edges`
- Guidance and routing: `route_checkpoints`
- Live context and quality: `hazard_reports`, `landmarks`, `landmark_verifications`, `map_contributions`

### APIs

- Map and graph: `POST /api/maps`, `GET /api/maps/:id/graph`
- Routing: `POST /api/navigation/routes`, `POST /api/navigation/routes/from-coordinates`, `POST /api/navigation/reroute`
- Live guidance: `POST /api/navigate`
- Hazard updates: `GET /api/hazards/nearby`

No new schema is required for this plan.

## Execution Plan

### Phase 1: Graph Readiness Baseline

Goal: Confirm existing map graphs can support routing immediately.

Actions:

- Inventory active maps in `room_maps` and verify node and edge density in `map_nodes` and `map_edges`.
- Reject maps with disconnected or sparse graph regions from pilot routing.
- Define pilot map list and approved start/end node pairs.

Done when:

- Pilot map set is finalized with valid start/end pairs.
- Each pilot map returns non-empty graph nodes and edges.

### Phase 2: Deterministic Route Generation

Goal: Produce reliable indoor paths from existing graph data.

Actions:

- Call `POST /api/navigation/routes/from-coordinates` when start/end are known as map-space coordinates.
- Call `POST /api/navigation/routes` with approved `mapId`, `startNodeId`, and `endNodeId`.
- Store and verify returned `routeId`, `nodeIds`, and checkpoints.
- Validate shortest-path behavior for normal and blocked-node scenarios.

Done when:

- Route requests consistently return `201` and non-empty `nodeIds`.
- Route checkpoints are returned or persisted in `route_checkpoints`.

### Phase 3: Live Instruction and Reroute Loop

Goal: Convert routes into real-time indoor guidance.

Actions:

- Send active context to `POST /api/navigate` (route id, heading, obstacles, speed).
- Poll `GET /api/hazards/nearby` and reroute using `POST /api/navigation/reroute` when path risk changes.
- Keep reroute node blocking aligned with active route context.

Done when:

- Guidance updates while moving and responds to obstacle/hazard changes.
- Reroute returns a new route when blocked nodes are supplied.

### Phase 4: Quality Controls and Pilot Exit

Goal: Ensure indoor navigation quality is stable for users.

Actions:

- Track route success rate, reroute frequency, and instruction latency.
- Use verification and contribution tables to improve landmark quality on failed routes.
- Run failure drills for disconnected maps and blocked-path scenarios.

Done when:

- KPIs meet target thresholds for pilot buildings.
- Failure cases have clear operator actions and recovery steps.

## KPI Targets

- Route success rate: >= 95%
- Median reroute latency: <= 2s
- Instruction latency: <= 2s
- Route failure due to graph gaps: < 5%

## Risks and Mitigations

- Graph gaps or disconnected edges
  - Mitigation: pre-approve pilot maps and start/end pairs only from validated graphs.
- Hazard spikes causing frequent reroutes
  - Mitigation: apply blocked-node logic and cooldown thresholds before reroute calls.
- AI availability or quota limits
  - Mitigation: keep routing deterministic from graph data; AI remains enhancement, not hard dependency.

## Immediate Weekly Plan

1. Build pilot map inventory and validate graph connectivity.
2. Define approved start/end node pairs for each pilot map.
3. Run scripted route, navigate, and reroute tests per map.
4. Record KPI baseline and route failure reasons.
5. Prioritize map fixes using verification and contribution workflows.
