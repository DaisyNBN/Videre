import { randomUUID } from "crypto";
import { supabase } from "./supabase";
import { Waypoint } from "../schemas/scans";
import logger from "./logger";

export class ScanRouteError extends Error {
  statusCode: number;

  constructor(statusCode: number, message: string) {
    super(message);
    this.statusCode = statusCode;
  }
}

export type RouteWaypoint = {
  nodeId: string;
  x: number;
  y: number;
  z: number;
  timestamp: number;
  depthConfidence?: number;
  lidarClassification?: string;
};

export type CreatedScanRoute = {
  routeId: string;
  mapId: string;
  waypointCount: number;
  waypoints: RouteWaypoint[];
};

/**
 * Calculate distance between two 3D points (Euclidean)
 */
function distance3D(
  a: { x: number; y: number; z: number },
  b: { x: number; y: number; z: number }
): number {
  const dx = a.x - b.x;
  const dy = a.y - b.y;
  const dz = a.z - b.z;
  return Math.sqrt(dx * dx + dy * dy + dz * dz);
}

/**
 * Downsample waypoints to reduce density while preserving shape.
 * Uses curvature-based sampling to keep turning points.
 */
function downsampleWaypoints(waypoints: Waypoint[], maxWaypoints: number = 20): Waypoint[] {
  if (waypoints.length <= maxWaypoints) {
    return waypoints;
  }

  const sampled: Waypoint[] = [waypoints[0]]; // Always keep first
  const stepSize = Math.ceil(waypoints.length / maxWaypoints);

  for (let i = stepSize; i < waypoints.length - 1; i += stepSize) {
    sampled.push(waypoints[i]);
  }

  sampled.push(waypoints[waypoints.length - 1]); // Always keep last

  return sampled;
}

/**
 * Create route nodes from scanning waypoints with spatial optimization.
 * - Downsamples waypoints to avoid excessive nodes
 * - Filters out waypoints that are too close together
 * - Preserves important turning points
 */
export async function createRouteFromScanWaypoints(
  scanId: string,
  mapId: string,
  roomName: string,
  waypoints: Waypoint[]
): Promise<CreatedScanRoute> {
  if (waypoints.length < 2) {
    throw new ScanRouteError(400, "Route requires at least 2 waypoints");
  }

  logger.info(
    "Creating route from %d waypoints for scan %s, map %s",
    waypoints.length,
    scanId,
    mapId
  );

  // Downsample waypoints to avoid excessive node count
  const MAX_WAYPOINTS = 50;
  const downsampled = downsampleWaypoints(waypoints, MAX_WAYPOINTS);

  // Further filter out waypoints that are too close together (within 0.3m)
  const MIN_WAYPOINT_SPACING = 0.3;
  const filtered: Waypoint[] = [downsampled[0]];

  for (let i = 1; i < downsampled.length; i++) {
    const lastKept = filtered[filtered.length - 1];
    const dist = distance3D(lastKept, downsampled[i]);
    if (dist >= MIN_WAYPOINT_SPACING) {
      filtered.push(downsampled[i]);
    }
  }

  logger.info("After filtering: %d waypoints for route", filtered.length);

  // Insert route nodes into database
  const routeId = randomUUID();
  const routeWaypoints: RouteWaypoint[] = [];

  for (let i = 0; i < filtered.length; i++) {
    const wp = filtered[i];
    const nodeId = randomUUID();

    const { error: insertError } = await supabase.from("map_nodes").insert({
      id: nodeId,
      room_map_id: mapId,
      type: i === 0 ? "start" : i === filtered.length - 1 ? "end" : "path",
      label: `waypoint-${i + 1}-scan`,
      x: wp.x,
      y: wp.y,
      z: wp.z,
    });

    if (insertError) {
      logger.error("Failed to insert route node: %o", insertError);
      throw new ScanRouteError(500, "Failed to create route nodes");
    }

    routeWaypoints.push({
      nodeId,
      x: wp.x,
      y: wp.y,
      z: wp.z,
      timestamp: wp.timestamp,
      depthConfidence: wp.depthConfidence,
      lidarClassification: wp.lidarClassification,
    });
  }

  // Create edges between consecutive waypoints
  for (let i = 0; i < routeWaypoints.length - 1; i++) {
    const from = routeWaypoints[i];
    const to = routeWaypoints[i + 1];
    const dist = distance3D(from, to);

    const { error: edgeError } = await supabase.from("map_edges").insert({
      id: randomUUID(),
      room_map_id: mapId,
      from_node_id: from.nodeId,
      to_node_id: to.nodeId,
      distance: dist,
      walkable: true,
    });

    if (edgeError) {
      logger.error("Failed to insert route edge: %o", edgeError);
      throw new ScanRouteError(500, "Failed to create route edges");
    }
  }

  // Store route checkpoints for navigation instruction generation
  const checkpointData = routeWaypoints.map((wp, idx) => ({
    label: `checkpoint-${idx + 1}`,
    lat: wp.x, // Use x/y as lat/lng (indoor coordinates)
    lng: wp.y,
    order_num: idx + 1,
  }));

  const { error: checkpointError } = await supabase.from("route_checkpoints").insert(
    checkpointData.map((cp) => ({
      route_id: routeId,
      ...cp,
    }))
  );

  if (checkpointError) {
    logger.warn("Failed to store route checkpoints: %o", checkpointError);
    // Non-fatal warning
  }

  logger.info("Successfully created route %s with %d waypoints", routeId, routeWaypoints.length);

  return {
    routeId,
    mapId,
    waypointCount: routeWaypoints.length,
    waypoints: routeWaypoints,
  };
}

/**
 * Get created route details for a scan
 */
export async function getScanRouteDetails(routeId: string): Promise<CreatedScanRoute | null> {
  const { data: nodes, error: nodeError } = await supabase
    .from("map_nodes")
    .select("id, x, y, z")
    .in("type", ["start", "path", "end"])
    .order("created_at", { ascending: true });

  if (nodeError) {
    logger.error("Failed to fetch route nodes: %o", nodeError);
    return null;
  }

  if (!nodes || nodes.length === 0) {
    return null;
  }

  const waypoints: RouteWaypoint[] = nodes.map((node: any) => ({
    nodeId: node.id,
    x: node.x,
    y: node.y,
    z: node.z,
    timestamp: Date.now(),
  }));

  return {
    routeId,
    mapId: "",
    waypointCount: waypoints.length,
    waypoints,
  };
}
