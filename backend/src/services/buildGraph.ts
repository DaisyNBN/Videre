import { randomUUID } from "crypto";
import { supabase } from "./supabase";
import { ScanPoint, Landmark, MapNode, MapEdge } from "../types";

function euclidean(a: { x: number; y: number; z: number }, b: { x: number; y: number; z: number }): number {
  return Math.sqrt((a.x - b.x) ** 2 + (a.y - b.y) ** 2 + (a.z - b.z) ** 2);
}

/**
 * Downsample dense scan points by picking every Nth point.
 * ARKit can produce thousands of points — we only need key waypoints.
 */
function downsample(points: ScanPoint[], maxNodes: number): ScanPoint[] {
  if (points.length <= maxNodes) return points;
  const step = Math.ceil(points.length / maxNodes);
  return points.filter((_, i) => i % step === 0);
}

export function buildGraphFromScan(
  points: ScanPoint[],
  landmarks: Landmark[],
  maxPathNodes: number = 50,
  edgeMaxDistance: number = 3.0
): { nodes: MapNode[]; edges: MapEdge[] } {
  const nodes: MapNode[] = [];

  const sampled = downsample(points, maxPathNodes);
  for (const p of sampled) {
    nodes.push({
      id: randomUUID(),
      type: "path",
      x: p.x,
      y: p.y,
      z: p.z,
    });
  }

  for (const lm of landmarks) {
    nodes.push({
      id: lm.id ?? randomUUID(),
      type: "landmark",
      label: lm.label ?? lm.type,
      x: lm.x,
      y: lm.y,
      z: lm.z,
    });
  }

  if (nodes.length > 0) {
    nodes[0].type = "start";
    nodes[nodes.length - 1].type = "end";
  }

  const edges: MapEdge[] = [];
  for (let i = 0; i < nodes.length; i++) {
    for (let j = i + 1; j < nodes.length; j++) {
      const dist = euclidean(nodes[i], nodes[j]);
      if (dist <= edgeMaxDistance) {
        edges.push({
          from: nodes[i].id,
          to: nodes[j].id,
          distance: Math.round(dist * 100) / 100,
          walkable: true,
        });
      }
    }
  }

  return { nodes, edges };
}

export async function buildAndSaveGraph(
  scanId: string,
  userId: string,
  roomName: string,
  points: ScanPoint[],
  landmarks: Landmark[]
): Promise<{ success: boolean; mapId?: string; error?: string }> {
  const { nodes, edges } = buildGraphFromScan(points, landmarks);

  const { data: roomMap, error: mapError } = await supabase
    .from("room_maps")
    .insert({
      room_name: roomName,
      created_by: userId,
    })
    .select("id")
    .single();

  if (mapError || !roomMap) {
    console.error("Room map insert error:", mapError?.message);
    return { success: false, error: mapError?.message ?? "Failed to create map" };
  }

  const mapId = roomMap.id;

  const nodeRows = nodes.map((n) => ({
    id: n.id,
    room_map_id: mapId,
    type: n.type,
    label: n.label ?? null,
    x: n.x,
    y: n.y,
    z: n.z,
  }));

  const { error: nodesError } = await supabase
    .from("map_nodes")
    .insert(nodeRows);

  if (nodesError) {
    console.error("Map nodes insert error:", nodesError.message);
    return { success: false, mapId, error: nodesError.message };
  }

  const edgeRows = edges.map((e) => ({
    room_map_id: mapId,
    from_node_id: e.from,
    to_node_id: e.to,
    distance: e.distance,
    walkable: e.walkable,
  }));

  if (edgeRows.length > 0) {
    const { error: edgesError } = await supabase
      .from("map_edges")
      .insert(edgeRows);

    if (edgesError) {
      console.error("Map edges insert error:", edgesError.message);
      return { success: false, mapId, error: edgesError.message };
    }
  }

  return { success: true, mapId };
}
