import { randomUUID } from "crypto";
import { NavRequest, NavResponse } from "../types";
import { supabase } from "./supabase";
import { haversineMeters } from "../utils/distance";
import { getGeminiNavResponse } from "./gemini";
import { getFallbackResponse } from "../fallback";
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

export type GenerateRouteRequest = {
  mapId: string;
  startNodeId: string;
  endNodeId: string;
  blockedNodeIds?: string[];
};

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

const MAX_REASONABLE_CHECKPOINT_DISTANCE_M = 1000;

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
        .select("id, label, x, y, z")
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

async function getNearestCheckpoint(
  routeId: string,
  location: { lat: number; lng: number },
): Promise<{ label: string; distance: number } | undefined> {
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
      return undefined;
    }

    logger.warn("Failed to fetch route checkpoints for nearest checkpoint: %o", error);
    return undefined;
  }

  let nearest: { label: string; distance: number } | undefined;

  if (checkpoints && checkpoints.length > 0) {
    let minDist = Number.POSITIVE_INFINITY;
    for (const cp of checkpoints) {
      const dist = haversineMeters(location.lat, location.lng, cp.lat, cp.lng);
      if (dist < minDist) {
        minDist = dist;
        nearest = { label: cp.label, distance: Math.round(dist) };
      }
    }
  }

  if (nearest && nearest.distance > MAX_REASONABLE_CHECKPOINT_DISTANCE_M) {
    logger.warn(
      "Ignoring nearest checkpoint for route %s because computed distance %d m looks uncalibrated.",
      routeId,
      nearest.distance,
    );
    return undefined;
  }

  return nearest;
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

function resolveRouteNodesFromCoordinates(
  nodesById: Map<string, RouteNodeRow>,
  start: { x: number; y: number; z?: number },
  end: { x: number; y: number; z?: number },
  blockedNodeIds: Set<string>,
): ResolvedRouteNodes {
  const candidates = Array.from(nodesById.values())
    .filter((node) => !blockedNodeIds.has(node.id));

  if (candidates.length === 0) {
    throw new NavigationError(404, "No available map nodes after blocked-node filtering");
  }

  const rankedStart = candidates
    .map((node) => ({ node, distance: distanceToNode(node, start) }))
    .sort((a, b) => a.distance - b.distance);

  const rankedEnd = candidates
    .map((node) => ({ node, distance: distanceToNode(node, end) }))
    .sort((a, b) => a.distance - b.distance);

  const bestStart = rankedStart[0];
  if (!bestStart) {
    throw new NavigationError(404, "Unable to resolve start node from map coordinates");
  }

  const bestEnd =
    rankedEnd.find((candidate) => candidate.node.id !== bestStart.node.id)
    ?? rankedEnd[0];

  if (!bestEnd) {
    throw new NavigationError(404, "Unable to resolve end node from map coordinates");
  }

  if (bestStart.node.id === bestEnd.node.id) {
    throw new NavigationError(
      400,
      "Start and end coordinates resolved to the same node; provide farther-apart coordinates",
    );
  }

  return {
    startNodeId: bestStart.node.id,
    endNodeId: bestEnd.node.id,
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
  const nearest = request.route_id
    ? await getNearestCheckpoint(request.route_id, request.location)
    : undefined;

  let response: NavResponse;
  try {
    response = await getGeminiNavResponse(request, nearest);
  } catch (err) {
    logger.error("Gemini failed in navigation pipeline: %o", err);
    response = getFallbackResponse(request.obstacles, nearest);
  }

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
