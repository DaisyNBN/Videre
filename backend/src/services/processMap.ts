import { randomUUID } from "crypto";
import { buildGraphFromScan } from "./buildGraph";
import supabase from "./supabase";
import { Landmark, ScanPoint } from "../types";
import { getScanById, ProcessScanError } from "./processScan";

export class ProcessMapError extends Error {
    statusCode: number;

    constructor(statusCode: number, message: string) {
        super(message);
        this.statusCode = statusCode;
    }
}

type CreateMapInput = {
    scanId?: string;
    roomName?: string;
    points?: ScanPoint[];
    landmarks?: Landmark[];
    createdBy?: string;
};

type MapRow = {
    id: string;
    room_name: string;
    created_by: string;
    created_at: string;
    version: number;
};

type MapNodeRow = {
    id: string;
    type: string;
    label: string | null;
    x: number;
    y: number;
    z: number;
};

type MapEdgeRow = {
    from_node_id: string;
    to_node_id: string;
    distance: number;
    walkable: boolean;
};

function asNumber(value: unknown, fallback = 0): number {
    if (typeof value === "number" && Number.isFinite(value)) {
        return value;
    }

    if (typeof value === "string") {
        const parsed = Number(value);
        if (Number.isFinite(parsed)) {
            return parsed;
        }
    }

    return fallback;
}

function normalizePoints(value: unknown): ScanPoint[] {
    if (!Array.isArray(value)) {
        return [];
    }

    return value
        .filter((point): point is Record<string, unknown> => {
            return typeof point === "object" && point !== null;
        })
        .map((point) => ({
            x: asNumber(point.x),
            y: asNumber(point.y),
            z: asNumber(point.z),
            timestamp:
                typeof point.timestamp === "number" && Number.isFinite(point.timestamp)
                    ? point.timestamp
                    : undefined,
        }));
}

function normalizeLandmarks(value: unknown): Landmark[] {
    if (!Array.isArray(value)) {
        return [];
    }

    return value
        .filter((landmark): landmark is Record<string, unknown> => {
            return typeof landmark === "object" && landmark !== null;
        })
        .map((landmark) => ({
            type:
                typeof landmark.type === "string"
                    ? (landmark.type as Landmark["type"])
                    : "unknown",
            label: typeof landmark.label === "string" ? landmark.label : undefined,
            confidence:
                typeof landmark.confidence === "number" &&
                    Number.isFinite(landmark.confidence)
                    ? landmark.confidence
                    : undefined,
            source: landmark.source === "gemini" ? "gemini" : "user",
            x: asNumber(landmark.x),
            y: asNumber(landmark.y),
            z: asNumber(landmark.z),
        }));
}

async function insertGraphRows(
    mapId: string,
    points: ScanPoint[],
    landmarks: Landmark[],
): Promise<{ nodeCount: number; edgeCount: number }> {
    const { nodes, edges } = buildGraphFromScan(points, landmarks);

    if (nodes.length === 0) {
        throw new ProcessMapError(400, "Map graph cannot be created from empty scan data");
    }

    const nodeRows = nodes.map((node) => ({
        id: node.id,
        room_map_id: mapId,
        type: node.type,
        label: node.label ?? null,
        x: node.x,
        y: node.y,
        z: node.z,
    }));

    const { error: nodeError } = await supabase.from("map_nodes").insert(nodeRows);

    if (nodeError) {
        throw new ProcessMapError(500, "Failed to create map nodes");
    }

    if (edges.length > 0) {
        const edgeRows = edges.map((edge) => ({
            room_map_id: mapId,
            from_node_id: edge.from,
            to_node_id: edge.to,
            distance: edge.distance,
            walkable: edge.walkable,
        }));

        const { error: edgeError } = await supabase.from("map_edges").insert(edgeRows);

        if (edgeError) {
            throw new ProcessMapError(500, "Failed to create map edges");
        }
    }

    return {
        nodeCount: nodes.length,
        edgeCount: edges.length,
    };
}

async function getScanPayload(scanId: string): Promise<{
    roomName: string;
    points: ScanPoint[];
    landmarks: Landmark[];
}> {
    try {
        const scan = (await getScanById(scanId)) as Record<string, unknown>;

        const roomName =
            typeof scan.room_name === "string" && scan.room_name.trim().length > 0
                ? scan.room_name
                : "Unlabeled Room";

        const points = normalizePoints(scan.points);
        const landmarks = normalizeLandmarks(scan.landmarks);

        return {
            roomName,
            points,
            landmarks,
        };
    } catch (error) {
        if (error instanceof ProcessScanError) {
            throw new ProcessMapError(error.statusCode, error.message);
        }

        throw new ProcessMapError(500, "Failed to load scan data for map creation");
    }
}

export async function createMap(input: CreateMapInput): Promise<{
    id: string;
    roomName: string;
    version: number;
    nodeCount: number;
    edgeCount: number;
    sourceScanId: string | null;
}> {
    let roomName = input.roomName?.trim() ?? "";
    let points = normalizePoints(input.points);
    let landmarks = normalizeLandmarks(input.landmarks);

    if (input.scanId) {
        const scanPayload = await getScanPayload(input.scanId);

        roomName = roomName || scanPayload.roomName;
        points = scanPayload.points;
        landmarks = scanPayload.landmarks;
    }

    if (!roomName) {
        throw new ProcessMapError(400, "roomName is required");
    }

    if (points.length === 0) {
        throw new ProcessMapError(400, "At least one scan point is required to build a map");
    }

    // Keep navigation graph deterministic and coordinate-first: do not include
    // AI-derived landmarks in the route graph source.
    landmarks = landmarks.filter((landmark) => landmark?.source !== "gemini");

    const { data: insertedMap, error: mapError } = await supabase
        .from("room_maps")
        .insert({
            room_name: roomName,
            created_by: input.createdBy ?? randomUUID(),
            version: 1,
        })
        .select("id, room_name, version")
        .single();

    if (mapError || !insertedMap?.id) {
        throw new ProcessMapError(500, "Failed to create map metadata");
    }

    const graphResult = await insertGraphRows(insertedMap.id, points, landmarks);

    return {
        id: insertedMap.id,
        roomName: insertedMap.room_name,
        version: insertedMap.version,
        nodeCount: graphResult.nodeCount,
        edgeCount: graphResult.edgeCount,
        sourceScanId: input.scanId ?? null,
    };
}

export async function listMaps(filters: {
    roomName?: string;
    version?: number;
    limit?: number;
    offset?: number;
}): Promise<{
    maps: MapRow[];
    limit: number;
    offset: number;
}> {
    const safeLimit = Math.min(Math.max(filters.limit ?? 25, 1), 100);
    const safeOffset = Math.max(filters.offset ?? 0, 0);

    let query = supabase
        .from("room_maps")
        .select("id, room_name, created_by, created_at, version")
        .order("created_at", { ascending: false })
        .range(safeOffset, safeOffset + safeLimit - 1);

    if (filters.roomName) {
        query = query.ilike("room_name", `%${filters.roomName}%`);
    }

    if (typeof filters.version === "number" && Number.isFinite(filters.version)) {
        query = query.eq("version", filters.version);
    }

    const { data, error } = await query;

    if (error) {
        throw new ProcessMapError(500, "Failed to list maps");
    }

    return {
        maps: (data ?? []) as MapRow[],
        limit: safeLimit,
        offset: safeOffset,
    };
}

export async function getMapById(mapId: string): Promise<MapRow> {
    const { data, error } = await supabase
        .from("room_maps")
        .select("id, room_name, created_by, created_at, version")
        .eq("id", mapId)
        .single();

    if (error) {
        if (error.code === "PGRST116") {
            throw new ProcessMapError(404, "Map not found");
        }

        throw new ProcessMapError(500, "Failed to fetch map");
    }

    if (!data) {
        throw new ProcessMapError(404, "Map not found");
    }

    return data as MapRow;
}

export async function getMapGraph(mapId: string): Promise<{
    mapId: string;
    nodes: MapNodeRow[];
    edges: MapEdgeRow[];
}> {
    await getMapById(mapId);

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
        throw new ProcessMapError(500, "Failed to fetch map graph");
    }

    return {
        mapId,
        nodes: (nodes ?? []) as MapNodeRow[],
        edges: (edges ?? []) as MapEdgeRow[],
    };
}

export async function createMapVersion(mapId: string): Promise<{
    id: string;
    roomName: string;
    version: number;
    sourceMapId: string;
    nodeCount: number;
    edgeCount: number;
}> {
    const baseMap = await getMapById(mapId);

    const { data: versionRows, error: versionError } = await supabase
        .from("room_maps")
        .select("version")
        .eq("room_name", baseMap.room_name)
        .order("version", { ascending: false })
        .limit(1);

    if (versionError) {
        throw new ProcessMapError(500, "Failed to determine next map version");
    }

    const highestVersion =
        Array.isArray(versionRows) && versionRows.length > 0
            ? asNumber(versionRows[0].version, 1)
            : 1;
    const nextVersion = highestVersion + 1;

    const { data: newMap, error: insertMapError } = await supabase
        .from("room_maps")
        .insert({
            room_name: baseMap.room_name,
            created_by: randomUUID(),
            version: nextVersion,
        })
        .select("id, room_name, version")
        .single();

    if (insertMapError || !newMap?.id) {
        throw new ProcessMapError(500, "Failed to create new map version");
    }

    const { data: oldNodes, error: oldNodesError } = await supabase
        .from("map_nodes")
        .select("id, type, label, x, y, z")
        .eq("room_map_id", mapId);

    if (oldNodesError) {
        throw new ProcessMapError(500, "Failed to fetch source map nodes");
    }

    const { data: oldEdges, error: oldEdgesError } = await supabase
        .from("map_edges")
        .select("from_node_id, to_node_id, distance, walkable")
        .eq("room_map_id", mapId);

    if (oldEdgesError) {
        throw new ProcessMapError(500, "Failed to fetch source map edges");
    }

    const nodeIdMap = new Map<string, string>();
    const clonedNodeRows = ((oldNodes ?? []) as MapNodeRow[]).map((node) => {
        const newNodeId = randomUUID();
        nodeIdMap.set(node.id, newNodeId);

        return {
            id: newNodeId,
            room_map_id: newMap.id,
            type: node.type,
            label: node.label,
            x: node.x,
            y: node.y,
            z: node.z,
        };
    });

    if (clonedNodeRows.length > 0) {
        const { error: insertNodesError } = await supabase
            .from("map_nodes")
            .insert(clonedNodeRows);

        if (insertNodesError) {
            throw new ProcessMapError(500, "Failed to clone map nodes");
        }
    }

    const clonedEdgeRows = ((oldEdges ?? []) as MapEdgeRow[])
        .map((edge) => {
            const fromNodeId = nodeIdMap.get(edge.from_node_id);
            const toNodeId = nodeIdMap.get(edge.to_node_id);

            if (!fromNodeId || !toNodeId) {
                return null;
            }

            return {
                room_map_id: newMap.id,
                from_node_id: fromNodeId,
                to_node_id: toNodeId,
                distance: edge.distance,
                walkable: edge.walkable,
            };
        })
        .filter(
            (
                edge,
            ): edge is {
                room_map_id: string;
                from_node_id: string;
                to_node_id: string;
                distance: number;
                walkable: boolean;
            } => edge !== null,
        );

    if (clonedEdgeRows.length > 0) {
        const { error: insertEdgesError } = await supabase
            .from("map_edges")
            .insert(clonedEdgeRows);

        if (insertEdgesError) {
            throw new ProcessMapError(500, "Failed to clone map edges");
        }
    }

    return {
        id: newMap.id,
        roomName: newMap.room_name,
        version: newMap.version,
        sourceMapId: mapId,
        nodeCount: clonedNodeRows.length,
        edgeCount: clonedEdgeRows.length,
    };
}
