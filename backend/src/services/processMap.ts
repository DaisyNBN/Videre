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

type CreateMapNodeInput = {
    mapId: string;
    type?: string;
    label?: string;
    x: number;
    y: number;
    z: number;
    autoConnect?: boolean;
    maxConnectionDistanceMeters?: number;
};

type PostgrestLikeError = {
    code?: string;
    message?: string;
};

const POINT_DEDUPE_GRID_METERS = 0.35;
const LANDMARK_DEDUPE_GRID_METERS = 0.75;
const DEFAULT_MAX_NODE_CONNECTION_DISTANCE_METERS = 12;
const VALID_MAP_NODE_TYPES = new Set(["path", "landmark", "start", "end"]);

function isMissingSchemaError(error: PostgrestLikeError | null | undefined): boolean {
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

function normalizeMapNodeType(type: string | undefined): string {
    if (type && VALID_MAP_NODE_TYPES.has(type)) {
        return type;
    }

    return "path";
}

function sanitizeOptionalLabel(label: string | undefined): string | null {
    const trimmed = label?.trim();
    if (!trimmed) {
        return null;
    }

    return trimmed;
}

function roundToHundredths(value: number): number {
    return Math.round(value * 100) / 100;
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

function pointBucketKey(point: Pick<ScanPoint, "x" | "y" | "z">): string {
    const bucket = POINT_DEDUPE_GRID_METERS;
    return [point.x, point.y, point.z]
        .map((value) => Math.round(value / bucket))
        .join(":");
}

function landmarkBucketKey(landmark: Pick<Landmark, "type" | "label" | "x" | "y" | "z">): string {
    const bucket = LANDMARK_DEDUPE_GRID_METERS;
    const label = (landmark.label ?? "").trim().toLowerCase();
    return [
        landmark.type,
        label,
        Math.round(landmark.x / bucket),
        Math.round(landmark.y / bucket),
        Math.round(landmark.z / bucket),
    ].join(":");
}

function mergeUniquePoints(primary: ScanPoint[], secondary: ScanPoint[]): ScanPoint[] {
    const seen = new Set<string>();
    const merged: ScanPoint[] = [];

    for (const point of [...primary, ...secondary]) {
        const key = pointBucketKey(point);
        if (seen.has(key)) {
            continue;
        }

        seen.add(key);
        merged.push(point);
    }

    return merged;
}

function mergeUniqueLandmarks(primary: Landmark[], secondary: Landmark[]): Landmark[] {
    const indexByKey = new Map<string, number>();
    const merged: Landmark[] = [];

    const upsert = (landmark: Landmark) => {
        const key = landmarkBucketKey(landmark);
        const existingIndex = indexByKey.get(key);

        if (existingIndex === undefined) {
            indexByKey.set(key, merged.length);
            merged.push(landmark);
            return;
        }

        const existing = merged[existingIndex];
        const existingConfidence = typeof existing.confidence === "number" ? existing.confidence : -1;
        const newConfidence = typeof landmark.confidence === "number" ? landmark.confidence : -1;
        if (newConfidence > existingConfidence) {
            merged[existingIndex] = landmark;
        }
    };

    for (const landmark of primary) {
        upsert(landmark);
    }

    for (const landmark of secondary) {
        upsert(landmark);
    }

    return merged;
}

async function readExistingMapGeometry(mapId: string): Promise<{
    points: ScanPoint[];
    landmarks: Landmark[];
    edgeCount: number;
}> {
    const [nodesResult, landmarksResult, edgesResult] = await Promise.all([
        supabase
            .from("map_nodes")
            .select("type, label, x, y, z")
            .eq("room_map_id", mapId),
        supabase
            .from("landmarks")
            .select("type, label, confidence, source, x, y, z")
            .eq("room_map_id", mapId),
        supabase
            .from("map_edges")
            .select("id")
            .eq("room_map_id", mapId),
    ]);

    if (nodesResult.error || landmarksResult.error || edgesResult.error) {
        throw new ProcessMapError(500, "Failed to read existing room map geometry");
    }

    const nodeRows = (nodesResult.data ?? []) as Array<{
        type: string;
        label: string | null;
        x: number;
        y: number;
        z: number;
    }>;

    const existingPoints: ScanPoint[] = nodeRows
        .filter((node) => node.type !== "landmark")
        .map((node) => ({
            x: node.x,
            y: node.y,
            z: node.z,
        }));

    const graphLandmarks: Landmark[] = nodeRows
        .filter((node) => node.type === "landmark")
        .map((node) => ({
            type: "unknown",
            label: node.label ?? "landmark",
            source: "user",
            x: node.x,
            y: node.y,
            z: node.z,
        }));

    const landmarkRows = (landmarksResult.data ?? []) as Array<{
        type: string;
        label: string | null;
        confidence: number | null;
        source: "user" | "gemini" | null;
        x: number;
        y: number;
        z: number;
    }>;

    const savedLandmarks: Landmark[] = landmarkRows.map((landmark) => ({
        type: (landmark.type as Landmark["type"]) ?? "unknown",
        label: landmark.label ?? "landmark",
        confidence: typeof landmark.confidence === "number" ? landmark.confidence : undefined,
        source: landmark.source === "gemini" ? "gemini" : "user",
        x: landmark.x,
        y: landmark.y,
        z: landmark.z,
    }));

    return {
        points: existingPoints,
        landmarks: mergeUniqueLandmarks(graphLandmarks, savedLandmarks),
        edgeCount: (edgesResult.data ?? []).length,
    };
}

async function resetMapGraphData(mapId: string): Promise<void> {
    const { error: edgeError } = await supabase
        .from("map_edges")
        .delete()
        .eq("room_map_id", mapId);

    if (edgeError) {
        throw new ProcessMapError(500, "Failed to clear previous map edges");
    }

    const { error: nodeError } = await supabase
        .from("map_nodes")
        .delete()
        .eq("room_map_id", mapId);

    if (nodeError) {
        throw new ProcessMapError(500, "Failed to clear previous map nodes");
    }
}

async function deleteMapsByIds(mapIds: string[]): Promise<void> {
    if (mapIds.length === 0) {
        return;
    }

    const { error: edgeError } = await supabase
        .from("map_edges")
        .delete()
        .in("room_map_id", mapIds);

    if (edgeError) {
        throw new ProcessMapError(500, "Failed to remove duplicate map edges");
    }

    const { error: nodeError } = await supabase
        .from("map_nodes")
        .delete()
        .in("room_map_id", mapIds);

    if (nodeError) {
        throw new ProcessMapError(500, "Failed to remove duplicate map nodes");
    }

    const { error: landmarkError } = await supabase
        .from("landmarks")
        .delete()
        .in("room_map_id", mapIds);

    if (landmarkError) {
        throw new ProcessMapError(500, "Failed to remove duplicate map landmarks");
    }

    const { error: contributionError } = await supabase
        .from("map_contributions")
        .delete()
        .in("map_id", mapIds);

    if (contributionError && !isMissingSchemaError(contributionError)) {
        throw new ProcessMapError(500, "Failed to remove duplicate map contributions");
    }

    const { error: mapError } = await supabase
        .from("room_maps")
        .delete()
        .in("id", mapIds);

    if (mapError) {
        throw new ProcessMapError(500, "Failed to remove duplicate maps");
    }
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

    const { data: existingMaps, error: existingError } = await supabase
        .from("room_maps")
        .select("id, room_name, version, created_at")
        .ilike("room_name", roomName)
        .order("created_at", { ascending: false });

    if (existingError) {
        throw new ProcessMapError(500, "Failed to check existing room map");
    }

    const existingRows = (existingMaps ?? []) as Array<MapRow & { created_at: string }>;
    let mapMeta: Pick<MapRow, "id" | "room_name" | "version">;

    if (existingRows.length > 0) {
        const primaryMap = existingRows[0];
        const existingGeometry = await readExistingMapGeometry(primaryMap.id);
        const mergedPoints = mergeUniquePoints(points, existingGeometry.points);
        const mergedLandmarks = mergeUniqueLandmarks(landmarks, existingGeometry.landmarks);

        const hasNewDetail =
            mergedPoints.length > existingGeometry.points.length ||
            mergedLandmarks.length > existingGeometry.landmarks.length;

        points = mergedPoints;
        landmarks = mergedLandmarks;

        const nextVersion =
            existingRows.reduce((maxVersion, row) => {
                return Math.max(maxVersion, asNumber(row.version, 1));
            }, 1) + 1;

        const duplicateMapIds = existingRows.slice(1).map((row) => row.id);
        await deleteMapsByIds(duplicateMapIds);

        if (!hasNewDetail) {
            mapMeta = {
                id: primaryMap.id,
                room_name: primaryMap.room_name,
                version: primaryMap.version,
            };

            return {
                id: mapMeta.id,
                roomName: mapMeta.room_name,
                version: mapMeta.version,
                nodeCount: existingGeometry.points.length + existingGeometry.landmarks.length,
                edgeCount: existingGeometry.edgeCount,
                sourceScanId: input.scanId ?? null,
            };
        }

        await resetMapGraphData(primaryMap.id);

        const { data: updatedMap, error: updateError } = await supabase
            .from("room_maps")
            .update({
                room_name: roomName,
                created_by: input.createdBy ?? randomUUID(),
                version: nextVersion,
                created_at: new Date().toISOString(),
            })
            .eq("id", primaryMap.id)
            .select("id, room_name, version")
            .single();

        if (updateError || !updatedMap?.id) {
            throw new ProcessMapError(500, "Failed to merge room rescan into existing map");
        }

        mapMeta = updatedMap as Pick<MapRow, "id" | "room_name" | "version">;
    } else {
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

        mapMeta = insertedMap as Pick<MapRow, "id" | "room_name" | "version">;
    }

    const graphResult = await insertGraphRows(mapMeta.id, points, landmarks);

    return {
        id: mapMeta.id,
        roomName: mapMeta.room_name,
        version: mapMeta.version,
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

export async function createMapNode(input: CreateMapNodeInput): Promise<{
    id: string;
    mapId: string;
    type: string;
    label: string | null;
    x: number;
    y: number;
    z: number;
    connectedToNodeId: string | null;
    connectedDistanceMeters: number | null;
}> {
    await getMapById(input.mapId);

    const nodeId = randomUUID();
    const resolvedType = normalizeMapNodeType(input.type);
    const resolvedLabel = sanitizeOptionalLabel(input.label);
    const shouldAutoConnect = input.autoConnect !== false;
    const maxConnectionDistanceMeters =
        typeof input.maxConnectionDistanceMeters === "number" &&
            Number.isFinite(input.maxConnectionDistanceMeters) &&
            input.maxConnectionDistanceMeters > 0
            ? input.maxConnectionDistanceMeters
            : DEFAULT_MAX_NODE_CONNECTION_DISTANCE_METERS;

    let connectedToNodeId: string | null = null;
    let connectedDistanceMeters: number | null = null;

    if (shouldAutoConnect) {
        const { data: existingNodes, error: existingNodesError } = await supabase
            .from("map_nodes")
            .select("id, x, y, z")
            .eq("room_map_id", input.mapId);

        if (existingNodesError) {
            throw new ProcessMapError(500, "Failed to inspect existing map nodes");
        }

        const nearestNode = ((existingNodes ?? []) as Array<{
            id: string;
            x: number;
            y: number;
            z: number;
        }>).reduce<{
            id: string;
            distance: number;
        } | null>((closest, node) => {
            const distance = Math.sqrt(
                (node.x - input.x) ** 2 +
                (node.y - input.y) ** 2 +
                (node.z - input.z) ** 2,
            );

            if (!closest || distance < closest.distance) {
                return {
                    id: node.id,
                    distance,
                };
            }

            return closest;
        }, null);

        if (nearestNode && nearestNode.distance <= maxConnectionDistanceMeters) {
            connectedToNodeId = nearestNode.id;
            connectedDistanceMeters = roundToHundredths(nearestNode.distance);
        }
    }

    const { error: insertNodeError } = await supabase.from("map_nodes").insert({
        id: nodeId,
        room_map_id: input.mapId,
        type: resolvedType,
        label: resolvedLabel,
        x: input.x,
        y: input.y,
        z: input.z,
    });

    if (insertNodeError) {
        throw new ProcessMapError(500, "Failed to create map node");
    }

    if (connectedToNodeId && connectedDistanceMeters !== null) {
        const { error: insertEdgeError } = await supabase.from("map_edges").insert({
            room_map_id: input.mapId,
            from_node_id: connectedToNodeId,
            to_node_id: nodeId,
            distance: connectedDistanceMeters,
            walkable: true,
        });

        if (insertEdgeError) {
            throw new ProcessMapError(500, "Failed to connect map node to graph");
        }
    }

    return {
        id: nodeId,
        mapId: input.mapId,
        type: resolvedType,
        label: resolvedLabel,
        x: input.x,
        y: input.y,
        z: input.z,
        connectedToNodeId,
        connectedDistanceMeters,
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
