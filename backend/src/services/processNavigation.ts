import { randomUUID } from "crypto";
import { NavRequest, NavResponse } from "../types";
import { supabase } from "./supabase";
import { haversineMeters } from "../utils/distance";
import { getNearbyHazards } from "./processHazard";
import logger from "./logger";

export class NavigationError extends Error {
  statusCode: number;

  constructor(statusCode: number, message: string) {
    super(message);
    this.statusCode = statusCode;
  }
}

type PostgrestLikeError = {
  code?: string;
  message?: string;
};

type RouteNodeRow = {
  id: string;
  type: string;
  label: string | null;
  x: number;
  y: number;
  z: number;
};

type RouteEdgeRow = {
  from_node_id: string;
  to_node_id: string;
  distance: number;
  walkable: boolean;
};

type RouteCheckpointRow = {
  label: string;
  lat: number;
  lng: number;
  order_num: number;
};

type RouteCheckpointCacheEntry = {
  checkpoints: RouteCheckpointRow[];
  cachedAtMs: number;
};

type CheckpointContext = {
  nearest: { label: string; distance: number; order: number };
  target: { label: string; distance: number; order: number; x: number; y: number };
  headingDeltaDegrees?: number;
};

type AdaptiveTurnThresholds = {
  straightDegrees: number;
  slightTurnDegrees: number;
  sharpTurnDegrees: number;
  checkpointAdvanceDistanceM: number;
};

const ROUTE_CHECKPOINT_CACHE_TTL_MS = 5_000;
const ROUTE_CHECKPOINT_CACHE_MAX_ENTRIES = 256;
const BASE_CHECKPOINT_ADVANCE_DISTANCE_M = 1.0;
const BASE_HEADING_STRAIGHT_DEGREES = 18;
const BASE_HEADING_SLIGHT_TURN_DEGREES = 50;
const BASE_HEADING_SHARP_TURN_DEGREES = 120;

const routeCheckpointCache = new Map<string, RouteCheckpointCacheEntry>();

export type GenerateRouteRequest = {
  mapId: string;
  startNodeId: string;
  endNodeId: string;
  blockedNodeIds?: string[];
};

function clampHeadingDelta(degrees: number): number {
  let delta = degrees;
  while (delta > 180) {
    delta -= 360;
  }
  while (delta <= -180) {
    delta += 360;
  }
  return delta;
}

function clamp(value: number, lower: number, upper: number): number {
  return Math.max(lower, Math.min(upper, value));
}

function resolveMovementSpeedMps(request: NavRequest): number {
  if (typeof request.speed_mps === "number" && Number.isFinite(request.speed_mps)) {
    return clamp(request.speed_mps, 0, 3);
  }

  return request.speed === "walking" ? 1.0 : 0.15;
}

function resolveAdaptiveTurnThresholds(speedMps: number): AdaptiveTurnThresholds {
  const fastFactor = clamp((speedMps - 0.2) / 1.6, 0, 1);
  const slowFactor = clamp((0.4 - speedMps) / 0.4, 0, 1);

  const straightDegrees =
    BASE_HEADING_STRAIGHT_DEGREES - (fastFactor * 5) + (slowFactor * 4);
  const slightTurnDegrees =
    BASE_HEADING_SLIGHT_TURN_DEGREES - (fastFactor * 10) + (slowFactor * 8);
  const sharpTurnDegrees =
    BASE_HEADING_SHARP_TURN_DEGREES - (fastFactor * 12) + (slowFactor * 8);

  const checkpointAdvanceDistanceM = clamp(
    BASE_CHECKPOINT_ADVANCE_DISTANCE_M + (fastFactor * 0.9) - (slowFactor * 0.35),
    0.65,
    2.2,
  );

  return {
    straightDegrees,
    slightTurnDegrees,
    sharpTurnDegrees,
    checkpointAdvanceDistanceM,
  };
}

function bearingDegreesFromMapVector(
  fromX: number,
  fromY: number,
  toX: number,
  toY: number,
): number | undefined {
  const dx = toX - fromX;
  const dy = toY - fromY;
  if (Math.abs(dx) < 1e-6 && Math.abs(dy) < 1e-6) {
    return undefined;
  }

  const radians = Math.atan2(dy, dx);
  const degrees = (radians * 180) / Math.PI;
  return (degrees + 360) % 360;
}

function normalizeHeadingDegrees(value: unknown): number | undefined {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return undefined;
  }

  let normalized = value % 360;
  if (normalized < 0) {
    normalized += 360;
  }

  return normalized;
}

async function loadRouteCheckpoints(routeId: string): Promise<RouteCheckpointRow[]> {
  const now = Date.now();
  const cached = routeCheckpointCache.get(routeId);
  if (cached && now - cached.cachedAtMs <= ROUTE_CHECKPOINT_CACHE_TTL_MS) {
    return cached.checkpoints;
  }

  const { data: checkpoints, error } = await supabase
    .from("route_checkpoints")
    .select("label, lat, lng, order_num")
    .eq("route_id", routeId)
    .order("order_num", { ascending: true });

  if (error) {
    if (isUndefinedTableOrColumn(error)) {
      logger.warn(
        "route_checkpoints schema unavailable for nearest-checkpoint lookup.",
      );
      return [];
    }

    logger.warn("Failed to fetch route checkpoints for nearest checkpoint: %o", error);
    return [];
  }

  const rows = (checkpoints ?? []) as RouteCheckpointRow[];
  routeCheckpointCache.set(routeId, {
    checkpoints: rows,
    cachedAtMs: now,
  });

  if (routeCheckpointCache.size > ROUTE_CHECKPOINT_CACHE_MAX_ENTRIES) {
    const oldest = routeCheckpointCache.entries().next().value as
      | [string, RouteCheckpointCacheEntry]
      | undefined;
    if (oldest) {
      routeCheckpointCache.delete(oldest[0]);
    }
  }

  return rows;
}

export type GenerateRouteFromCoordinatesRequest = {
  mapId: string;
  start: {
    x: number;
    y: number;
    z?: number;
  };
  end: {
    x: number;
    y: number;
    z?: number;
  };
  blockedNodeIds?: string[];
};

export type GenerateRouteToRoomRequest = {
  mapId: string;
  start: {
    x: number;
    y: number;
    z?: number;
  };
  destinationLabel: string;
  blockedNodeIds?: string[];
};

export type GeneratedRoute = {
  routeId: string;
  mapId: string;
  startNodeId: string;
  endNodeId: string;
  nodeIds: string[];
  checkpoints: Array<{
    order: number;
    nodeId: string;
    label: string;
    x: number;
    y: number;
    z: number;
  }>;
  checkpointStorage: "persisted" | "in-memory";
};

export type RerouteRequest = GenerateRouteRequest & {
  obstacleNodeIds?: string[];
  reason?: string;
};

export type RerouteResult = GeneratedRoute & {
  rerouted: true;
  reason: string | null;
};

type ResolvedRouteNodes = {
  startNodeId: string;
  endNodeId: string;
  startDistance: number;
  endDistance: number;
};

type DestinationLandmarkRow = {
  id: string;
  label: string | null;
  type: string;
  confidence: number | null;
  status: string | null;
  x: number;
  y: number;
  z: number;
};

function isUndefinedTableOrColumn(error: PostgrestLikeError | null | undefined): boolean {
  if (!error) {
    return false;
  }

  return (
    error.code === "42P01" ||
    error.code === "42703" ||
    /relation\s+.+\s+does not exist/i.test(error.message ?? "") ||
    /column\s+.+\s+does not exist/i.test(error.message ?? "")
  );
}

async function loadRouteGraph(mapId: string): Promise<{
  nodesById: Map<string, RouteNodeRow>;
  edges: RouteEdgeRow[];
}> {
  const [{ data: nodes, error: nodeError }, { data: edges, error: edgeError }] =
    await Promise.all([
      supabase
        .from("map_nodes")
        .select("id, type, label, x, y, z")
        .eq("room_map_id", mapId),
      supabase
        .from("map_edges")
        .select("from_node_id, to_node_id, distance, walkable")
        .eq("room_map_id", mapId),
    ]);

  if (nodeError || edgeError) {
    logger.error("Failed loading map graph for navigation route generation");
    throw new NavigationError(500, "Failed to load map graph");
  }

  const nodeRows = (nodes ?? []) as RouteNodeRow[];
  if (nodeRows.length === 0) {
    throw new NavigationError(404, "No graph nodes found for the provided map");
  }

  const nodesById = new Map<string, RouteNodeRow>();
  for (const node of nodeRows) {
    nodesById.set(node.id, node);
  }

  return {
    nodesById,
    edges: (edges ?? []) as RouteEdgeRow[],
  };
}

function buildAdjacency(
  nodesById: Map<string, RouteNodeRow>,
  edges: RouteEdgeRow[],
  blockedNodeIds: Set<string>,
): Map<string, Array<{ nodeId: string; distance: number }>> {
  const adjacency = new Map<string, Array<{ nodeId: string; distance: number }>>();

  for (const nodeId of nodesById.keys()) {
    if (!blockedNodeIds.has(nodeId)) {
      adjacency.set(nodeId, []);
    }
  }

  for (const edge of edges) {
    if (!edge.walkable) {
      continue;
    }

    if (
      blockedNodeIds.has(edge.from_node_id) ||
      blockedNodeIds.has(edge.to_node_id) ||
      !adjacency.has(edge.from_node_id) ||
      !adjacency.has(edge.to_node_id)
    ) {
      continue;
    }

    const weight =
      typeof edge.distance === "number" && Number.isFinite(edge.distance)
        ? Math.max(edge.distance, 0)
        : 0;

    adjacency.get(edge.from_node_id)?.push({ nodeId: edge.to_node_id, distance: weight });
    adjacency.get(edge.to_node_id)?.push({ nodeId: edge.from_node_id, distance: weight });
  }

  return adjacency;
}

function computeShortestPath(
  adjacency: Map<string, Array<{ nodeId: string; distance: number }>>,
  startNodeId: string,
  endNodeId: string,
): string[] {
  const dist = new Map<string, number>();
  const prev = new Map<string, string | null>();
  const unvisited = new Set<string>();

  for (const nodeId of adjacency.keys()) {
    dist.set(nodeId, Number.POSITIVE_INFINITY);
    prev.set(nodeId, null);
    unvisited.add(nodeId);
  }

  if (!unvisited.has(startNodeId) || !unvisited.has(endNodeId)) {
    return [];
  }

  dist.set(startNodeId, 0);

  while (unvisited.size > 0) {
    let current: string | null = null;
    let bestDistance = Number.POSITIVE_INFINITY;

    for (const nodeId of unvisited) {
      const nodeDistance = dist.get(nodeId) ?? Number.POSITIVE_INFINITY;
      if (nodeDistance < bestDistance) {
        bestDistance = nodeDistance;
        current = nodeId;
      }
    }

    if (!current || !Number.isFinite(bestDistance)) {
      break;
    }

    unvisited.delete(current);

    if (current === endNodeId) {
      break;
    }

    const neighbors = adjacency.get(current) ?? [];
    for (const neighbor of neighbors) {
      if (!unvisited.has(neighbor.nodeId)) {
        continue;
      }

      const altDistance = bestDistance + neighbor.distance;
      if (altDistance < (dist.get(neighbor.nodeId) ?? Number.POSITIVE_INFINITY)) {
        dist.set(neighbor.nodeId, altDistance);
        prev.set(neighbor.nodeId, current);
      }
    }
  }

  if ((dist.get(endNodeId) ?? Number.POSITIVE_INFINITY) === Number.POSITIVE_INFINITY) {
    return [];
  }

  const path: string[] = [];
  let cursor: string | null = endNodeId;
  while (cursor) {
    path.unshift(cursor);
    cursor = prev.get(cursor) ?? null;
  }

  return path;
}

async function persistRouteCheckpoints(
  routeId: string,
  checkpoints: RouteCheckpointRow[],
): Promise<"persisted" | "in-memory"> {
  routeCheckpointCache.set(routeId, {
    checkpoints,
    cachedAtMs: Date.now(),
  });

  if (routeCheckpointCache.size > ROUTE_CHECKPOINT_CACHE_MAX_ENTRIES) {
    const oldest = routeCheckpointCache.entries().next().value as
      | [string, RouteCheckpointCacheEntry]
      | undefined;
    if (oldest) {
      routeCheckpointCache.delete(oldest[0]);
    }
  }

  if (checkpoints.length === 0) {
    return "in-memory";
  }

  const { error } = await supabase.from("route_checkpoints").insert(
    checkpoints.map((cp) => ({
      route_id: routeId,
      order_num: cp.order_num,
      lat: cp.lat,
      lng: cp.lng,
      label: cp.label,
      instruction:
        cp.order_num === 1
          ? `Start at ${cp.label}`
          : `Proceed to ${cp.label}`,
    })),
  );

  if (error) {
    if (isUndefinedTableOrColumn(error)) {
      logger.warn(
        "route_checkpoints table/columns unavailable; route checkpoints returned in-memory only.",
      );
      return "in-memory";
    }

    logger.warn("Failed to persist route checkpoints: %o", error);
    return "in-memory";
  }

  return "persisted";
}

async function getCheckpointContext(
  routeId: string,
  location: { lat: number; lng: number },
  mapPosition?: { x: number; y: number; z?: number },
  headingDegrees?: number,
  checkpointAdvanceDistanceM: number = BASE_CHECKPOINT_ADVANCE_DISTANCE_M,
): Promise<CheckpointContext | undefined> {
  const checkpoints = await loadRouteCheckpoints(routeId);
  if (checkpoints.length === 0) {
    return undefined;
  }

  const distanceForCheckpoint = (checkpoint: RouteCheckpointRow): number => {
    if (typeof mapPosition?.x === "number" && typeof mapPosition?.y === "number") {
      return Math.hypot(checkpoint.lat - mapPosition.x, checkpoint.lng - mapPosition.y);
    }

    return haversineMeters(location.lat, location.lng, checkpoint.lat, checkpoint.lng);
  };

  let nearestIndex = 0;
  let nearestDistance = Number.POSITIVE_INFINITY;

  for (let i = 0; i < checkpoints.length; i += 1) {
    const distance = distanceForCheckpoint(checkpoints[i]);
    if (distance < nearestDistance) {
      nearestDistance = distance;
      nearestIndex = i;
    }
  }

  let targetIndex = nearestIndex;
  if (
    typeof mapPosition?.x === "number" &&
    typeof mapPosition?.y === "number" &&
    nearestDistance <= checkpointAdvanceDistanceM &&
    nearestIndex < checkpoints.length - 1
  ) {
    targetIndex = nearestIndex + 1;
  }

  const nearest = checkpoints[nearestIndex];
  const target = checkpoints[targetIndex];
  const targetDistance = distanceForCheckpoint(target);

  let headingDeltaDegrees: number | undefined;
  if (
    typeof headingDegrees === "number" &&
    Number.isFinite(headingDegrees) &&
    typeof mapPosition?.x === "number" &&
    typeof mapPosition?.y === "number"
  ) {
    const desiredHeading = bearingDegreesFromMapVector(
      mapPosition.x,
      mapPosition.y,
      target.lat,
      target.lng,
    );

    if (typeof desiredHeading === "number") {
      headingDeltaDegrees = clampHeadingDelta(desiredHeading - headingDegrees);
    }
  }

  return {
    nearest: {
      label: nearest.label,
      distance: Number(nearestDistance.toFixed(2)),
      order: nearest.order_num,
    },
    target: {
      label: target.label,
      distance: Number(targetDistance.toFixed(2)),
      order: target.order_num,
      x: target.lat,
      y: target.lng,
    },
    headingDeltaDegrees,
  };
}

function toCheckpointSummary(
  checkpointContext?: CheckpointContext,
): { label: string; distance: number } | undefined {
  if (!checkpointContext) {
    return undefined;
  }

  return {
    label: checkpointContext.target.label,
    distance: Math.max(0, Math.round(checkpointContext.target.distance)),
  };
}

function resolveSpokenCheckpointLabel(label: string | undefined): string | undefined {
  const normalized = label?.trim();
  if (!normalized) {
    return undefined;
  }

  if (/^node-\d+$/i.test(normalized)) {
    return undefined;
  }

  return normalized;
}

function buildDeterministicRouteResponse(
  request: NavRequest,
  checkpointContext?: CheckpointContext,
): NavResponse {
  const movementSpeedMps = resolveMovementSpeedMps(request);
  const thresholds = resolveAdaptiveTurnThresholds(movementSpeedMps);
  const checkpointSummary = toCheckpointSummary(checkpointContext);
  const blocking = request.obstacles.find(
    (obstacle) => obstacle.distance_estimate === "near" && obstacle.position === "center",
  );
  if (blocking) {
    return {
      instruction: `${blocking.label} ahead. Stop. Step right.`,
      urgency: "high",
      haptic_pattern: "continuous",
      next_checkpoint: checkpointSummary?.label ?? null,
      distance_to_next_m: checkpointSummary?.distance ?? null,
      fallback_used: false,
    };
  }

  const nearbyObstacle = request.obstacles.find(
    (obstacle) => obstacle.distance_estimate === "near",
  );
  if (nearbyObstacle) {
    const avoidDir = nearbyObstacle.position === "left" ? "right" : "left";
    return {
      instruction: `${nearbyObstacle.label} on your ${nearbyObstacle.position}. Keep ${avoidDir}.`,
      urgency: "medium",
      haptic_pattern: "double_tap",
      next_checkpoint: checkpointSummary?.label ?? null,
      distance_to_next_m: checkpointSummary?.distance ?? null,
      fallback_used: false,
    };
  }

  if (!checkpointContext) {
    return {
      instruction: "Continue straight.",
      urgency: "low",
      haptic_pattern: "single_tap",
      next_checkpoint: null,
      distance_to_next_m: null,
      fallback_used: false,
    };
  }

  let urgency: NavResponse["urgency"] = "low";
  let hapticPattern: NavResponse["haptic_pattern"] = "single_tap";
  let turnPrompt = "Continue straight";

  if (typeof checkpointContext.headingDeltaDegrees === "number") {
    const delta = checkpointContext.headingDeltaDegrees;
    const absDelta = Math.abs(delta);

    if (absDelta <= thresholds.straightDegrees) {
      turnPrompt = "Continue straight";
    } else if (absDelta <= thresholds.slightTurnDegrees) {
      turnPrompt = delta > 0 ? "Slight right" : "Slight left";
      urgency = "medium";
      hapticPattern = "double_tap";
    } else if (absDelta <= thresholds.sharpTurnDegrees) {
      turnPrompt = delta > 0 ? "Turn right" : "Turn left";
      urgency = "medium";
      hapticPattern = "double_tap";
    } else {
      turnPrompt = delta > 0 ? "Turn around to your right" : "Turn around to your left";
      urgency = "high";
      hapticPattern = "continuous";
    }
  }

  const remainingDistance = checkpointContext.target.distance;
  const roundedDistance = Math.max(0, Math.round(remainingDistance));
  const spokenTargetLabel = resolveSpokenCheckpointLabel(checkpointContext.target.label);
  const absHeadingDelta = typeof checkpointContext.headingDeltaDegrees === "number"
    ? Math.abs(checkpointContext.headingDeltaDegrees)
    : undefined;

  let instruction: string;
  if (remainingDistance <= 2.2) {
    const sideCue =
      typeof checkpointContext.headingDeltaDegrees === "number"
        ? absHeadingDelta !== undefined && absHeadingDelta <= 25
          ? "ahead"
          : checkpointContext.headingDeltaDegrees > 0
            ? "on your right"
            : "on your left"
        : "nearby";
    instruction = spokenTargetLabel
      ? `${turnPrompt}. ${spokenTargetLabel} should be ${sideCue}.`
      : `${turnPrompt}. The next point should be ${sideCue}.`;
  } else {
    instruction = spokenTargetLabel
      ? `${turnPrompt}. Continue about ${roundedDistance} meters toward ${spokenTargetLabel}.`
      : `${turnPrompt}. Continue about ${roundedDistance} meters.`;
  }

  return {
    instruction,
    urgency,
    haptic_pattern: hapticPattern,
    next_checkpoint: checkpointContext.target.label,
    distance_to_next_m: Number(checkpointContext.target.distance.toFixed(1)),
    fallback_used: false,
  };
}

function distanceToNode(
  node: RouteNodeRow,
  point: { x: number; y: number; z?: number },
): number {
  const dx = node.x - point.x;
  const dy = node.y - point.y;
  const dz = typeof point.z === "number" ? node.z - point.z : 0;
  return Math.sqrt((dx * dx) + (dy * dy) + (dz * dz));
}

function normalizeText(value: string): string {
  return value.trim().toLowerCase();
}

function labelsRoughlyMatch(label: string, query: string): boolean {
  return (
    label === query ||
    label.startsWith(query) ||
    label.includes(query) ||
    query.includes(label)
  );
}

function scoreLabelMatch(
  label: string,
  query: string,
): number {
  if (label === query) {
    return 100;
  }

  if (label.startsWith(query)) {
    return 85;
  }

  if (label.includes(query)) {
    return 70;
  }

  if (query.includes(label)) {
    return 55;
  }

  return 0;
}

function resolveNearestNodeFromPoint(
  nodesById: Map<string, RouteNodeRow>,
  point: { x: number; y: number; z?: number },
  blockedNodeIds: Set<string>,
  excludeNodeIds: Set<string> = new Set(),
): { nodeId: string; distance: number } {
  const candidates = Array.from(nodesById.values())
    .filter((node) => !blockedNodeIds.has(node.id) && !excludeNodeIds.has(node.id));

  if (candidates.length === 0) {
    throw new NavigationError(404, "No available map nodes after filtering");
  }

  const ranked = candidates
    .map((node) => ({ nodeId: node.id, distance: distanceToNode(node, point) }))
    .sort((a, b) => a.distance - b.distance);

  const best = ranked[0];
  if (!best) {
    throw new NavigationError(404, "Unable to resolve nearest node from provided coordinates");
  }

  return best;
}

async function resolveDestinationLandmark(
  mapId: string,
  destinationLabel: string,
): Promise<DestinationLandmarkRow> {
  const { data, error } = await supabase
    .from("landmarks")
    .select("id, label, type, confidence, status, x, y, z")
    .eq("room_map_id", mapId);

  if (error) {
    if (isUndefinedTableOrColumn(error)) {
      throw new NavigationError(
        500,
        "Landmark storage is unavailable for room destination routing",
      );
    }

    logger.error("Failed to load landmarks for room destination routing: %o", error);
    throw new NavigationError(500, "Failed to resolve destination room");
  }

  const query = normalizeText(destinationLabel);
  const candidates = ((data ?? []) as DestinationLandmarkRow[])
    .filter((landmark) => typeof landmark.label === "string" && landmark.label.trim().length > 0)
    .filter((landmark) => {
      const label = normalizeText(landmark.label ?? "");
      return labelsRoughlyMatch(label, query);
    })
    .map((landmark) => {
      const label = normalizeText(landmark.label ?? "");
      let score = scoreLabelMatch(label, query);

      if (landmark.status === "verified") {
        score += 12;
      } else if (landmark.status === "pending") {
        score += 4;
      } else if (landmark.status === "rejected") {
        score -= 12;
      }

      if (typeof landmark.confidence === "number" && Number.isFinite(landmark.confidence)) {
        score += Math.max(0, Math.min(landmark.confidence, 1)) * 10;
      }

      return {
        landmark,
        score,
      };
    })
    .sort((a, b) => b.score - a.score);

  if (candidates.length === 0) {
    throw new NavigationError(
      404,
      `No destination room matched label \"${destinationLabel}\" on this map`,
    );
  }

  return candidates[0].landmark;
}

async function resolveDestinationNodeFromRoomName(
  mapId: string,
  destinationLabel: string,
  nodesById: Map<string, RouteNodeRow>,
  start: { x: number; y: number; z?: number },
  startNodeId: string,
  blockedNodeIds: Set<string>,
): Promise<{
  nodeId: string;
  label: string;
  type: string;
  status: string | null;
  confidence: number | null;
} | undefined> {
  const { data, error } = await supabase
    .from("room_maps")
    .select("room_name")
    .eq("id", mapId)
    .single();

  if (error || !data) {
    return undefined;
  }

  const roomName = normalizeText((data as { room_name?: string }).room_name ?? "");
  const query = normalizeText(destinationLabel);
  if (!roomName || !query || !labelsRoughlyMatch(roomName, query)) {
    return undefined;
  }

  const candidates = Array.from(nodesById.values()).filter((node) => {
    return !blockedNodeIds.has(node.id) && node.id !== startNodeId;
  });

  if (candidates.length === 0) {
    return undefined;
  }

  const labelledMatches = candidates
    .filter((node) => typeof node.label === "string" && node.label.trim().length > 0)
    .map((node) => {
      const nodeLabel = normalizeText(node.label ?? "");
      return {
        node,
        score: scoreLabelMatch(nodeLabel, query),
        distance: distanceToNode(node, start),
      };
    })
    .filter((candidate) => candidate.score > 0)
    .sort((lhs, rhs) => {
      if (lhs.score !== rhs.score) {
        return rhs.score - lhs.score;
      }
      return lhs.distance - rhs.distance;
    });

  if (labelledMatches.length > 0) {
    const best = labelledMatches[0].node;
    return {
      nodeId: best.id,
      label: best.label ?? destinationLabel,
      type: "room",
      status: null,
      confidence: null,
    };
  }

  const endNode = candidates.find((node) => normalizeText(node.type) === "end");
  if (endNode) {
    return {
      nodeId: endNode.id,
      label: endNode.label ?? destinationLabel,
      type: "room",
      status: null,
      confidence: null,
    };
  }

  const farthest = candidates
    .map((node) => ({ node, distance: distanceToNode(node, start) }))
    .sort((lhs, rhs) => rhs.distance - lhs.distance)[0]?.node;

  if (!farthest) {
    return undefined;
  }

  return {
    nodeId: farthest.id,
    label: farthest.label ?? destinationLabel,
    type: "room",
    status: null,
    confidence: null,
  };
}

function resolveRouteNodesFromCoordinates(
  nodesById: Map<string, RouteNodeRow>,
  start: { x: number; y: number; z?: number },
  end: { x: number; y: number; z?: number },
  blockedNodeIds: Set<string>,
): ResolvedRouteNodes {
  const bestStart = resolveNearestNodeFromPoint(nodesById, start, blockedNodeIds);
  const bestEnd = resolveNearestNodeFromPoint(
    nodesById,
    end,
    blockedNodeIds,
    new Set([bestStart.nodeId]),
  );

  return {
    startNodeId: bestStart.nodeId,
    endNodeId: bestEnd.nodeId,
    startDistance: bestStart.distance,
    endDistance: bestEnd.distance,
  };
}

export async function generateNavigationRoute(
  request: GenerateRouteRequest,
): Promise<GeneratedRoute> {
  const { mapId, startNodeId, endNodeId } = request;

  if (!mapId || !startNodeId || !endNodeId) {
    throw new NavigationError(400, "mapId, startNodeId, and endNodeId are required");
  }

  const blockedNodeIds = new Set(
    (request.blockedNodeIds ?? []).filter((nodeId) => typeof nodeId === "string"),
  );

  if (blockedNodeIds.has(startNodeId) || blockedNodeIds.has(endNodeId)) {
    throw new NavigationError(400, "Start or end node cannot be blocked");
  }

  const { nodesById, edges } = await loadRouteGraph(mapId);

  if (!nodesById.has(startNodeId) || !nodesById.has(endNodeId)) {
    throw new NavigationError(404, "Start or end node not found in map graph");
  }

  const adjacency = buildAdjacency(nodesById, edges, blockedNodeIds);
  const nodePath = computeShortestPath(adjacency, startNodeId, endNodeId);

  if (nodePath.length === 0) {
    throw new NavigationError(404, "No walkable route found for the requested nodes");
  }

  const routeId = randomUUID();
  const checkpointView = nodePath.map((nodeId, index) => {
    const node = nodesById.get(nodeId)!;
    const fallbackLabel = `node-${index + 1}`;

    return {
      order: index + 1,
      nodeId,
      label: node.label ?? fallbackLabel,
      x: node.x,
      y: node.y,
      z: node.z,
    };
  });

  const checkpointStorage = await persistRouteCheckpoints(
    routeId,
    checkpointView.map((cp) => ({
      label: cp.label,
      lat: cp.x,
      lng: cp.y,
      order_num: cp.order,
    })),
  );

  return {
    routeId,
    mapId,
    startNodeId,
    endNodeId,
    nodeIds: nodePath,
    checkpoints: checkpointView,
    checkpointStorage,
  };
}

export async function generateNavigationRouteFromCoordinates(
  request: GenerateRouteFromCoordinatesRequest,
): Promise<GeneratedRoute & {
  resolvedFromCoordinates: {
    startDistance: number;
    endDistance: number;
  };
}> {
  const { mapId, start, end } = request;

  if (!mapId || !start || !end) {
    throw new NavigationError(400, "mapId, start, and end coordinates are required");
  }

  const blockedNodeIds = new Set(
    (request.blockedNodeIds ?? []).filter((nodeId) => typeof nodeId === "string"),
  );

  const { nodesById } = await loadRouteGraph(mapId);
  const resolved = resolveRouteNodesFromCoordinates(
    nodesById,
    start,
    end,
    blockedNodeIds,
  );

  const route = await generateNavigationRoute({
    mapId,
    startNodeId: resolved.startNodeId,
    endNodeId: resolved.endNodeId,
    blockedNodeIds: [...blockedNodeIds],
  });

  return {
    ...route,
    resolvedFromCoordinates: {
      startDistance: Number(resolved.startDistance.toFixed(3)),
      endDistance: Number(resolved.endDistance.toFixed(3)),
    },
  };
}

export async function generateNavigationRouteToRoom(
  request: GenerateRouteToRoomRequest,
): Promise<GeneratedRoute & {
  destination: {
    landmarkId: string;
    label: string;
    type: string;
    status: string | null;
    confidence: number | null;
  };
  resolvedFromCoordinates: {
    startDistance: number;
    destinationDistance: number;
  };
}> {
  const { mapId, start, destinationLabel } = request;

  if (!mapId || !start || !destinationLabel?.trim()) {
    throw new NavigationError(400, "mapId, start coordinates, and destinationLabel are required");
  }

  const blockedNodeIds = new Set(
    (request.blockedNodeIds ?? []).filter((nodeId) => typeof nodeId === "string"),
  );

  const { nodesById } = await loadRouteGraph(mapId);
  const startNode = resolveNearestNodeFromPoint(nodesById, start, blockedNodeIds);

  let destinationNode: { nodeId: string; distance: number };
  let destinationMetadata: {
    landmarkId: string;
    label: string;
    type: string;
    status: string | null;
    confidence: number | null;
  };

  try {
    const destinationLandmark = await resolveDestinationLandmark(mapId, destinationLabel);
    destinationNode = resolveNearestNodeFromPoint(
      nodesById,
      { x: destinationLandmark.x, y: destinationLandmark.y, z: destinationLandmark.z },
      blockedNodeIds,
      new Set([startNode.nodeId]),
    );

    destinationMetadata = {
      landmarkId: destinationLandmark.id,
      label: destinationLandmark.label ?? destinationLabel,
      type: destinationLandmark.type,
      status: destinationLandmark.status,
      confidence: destinationLandmark.confidence,
    };
  } catch (error) {
    if (!(error instanceof NavigationError) || error.statusCode !== 404) {
      throw error;
    }

    const fallback = await resolveDestinationNodeFromRoomName(
      mapId,
      destinationLabel,
      nodesById,
      start,
      startNode.nodeId,
      blockedNodeIds,
    );

    if (!fallback) {
      throw error;
    }

    destinationNode = {
      nodeId: fallback.nodeId,
      distance: 0,
    };

    destinationMetadata = {
      landmarkId: fallback.nodeId,
      label: fallback.label,
      type: fallback.type,
      status: fallback.status,
      confidence: fallback.confidence,
    };
  }

  const route = await generateNavigationRoute({
    mapId,
    startNodeId: startNode.nodeId,
    endNodeId: destinationNode.nodeId,
    blockedNodeIds: [...blockedNodeIds],
  });

  return {
    ...route,
    destination: destinationMetadata,
    resolvedFromCoordinates: {
      startDistance: Number(startNode.distance.toFixed(3)),
      destinationDistance: Number(destinationNode.distance.toFixed(3)),
    },
  };
}

export async function rerouteNavigation(
  request: RerouteRequest,
): Promise<RerouteResult> {
  const blockedNodeIds = new Set<string>(request.blockedNodeIds ?? []);

  for (const nodeId of request.obstacleNodeIds ?? []) {
    blockedNodeIds.add(nodeId);
  }

  const route = await generateNavigationRoute({
    mapId: request.mapId,
    startNodeId: request.startNodeId,
    endNodeId: request.endNodeId,
    blockedNodeIds: [...blockedNodeIds],
  });

  return {
    ...route,
    rerouted: true,
    reason: request.reason ?? null,
  };
}

export async function getNavigationInstruction(
  request: NavRequest
): Promise<NavResponse> {
  const movementSpeedMps = resolveMovementSpeedMps(request);
  const adaptiveThresholds = resolveAdaptiveTurnThresholds(movementSpeedMps);

  const checkpointContext = request.route_id
    ? await getCheckpointContext(
      request.route_id,
      request.location,
      request.map_position,
      request.heading_degrees,
      adaptiveThresholds.checkpointAdvanceDistanceM,
    )
    : undefined;

  const response: NavResponse = buildDeterministicRouteResponse(
    request,
    checkpointContext,
  );

  const hazards = await getNearbyHazards(
    request.location.lat,
    request.location.lng,
    50
  );

  if (hazards.length > 0 && response.urgency === "low") {
    response.urgency = "medium";
    response.haptic_pattern = "double_tap";
  }

  return response;
}
