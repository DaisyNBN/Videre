import { randomUUID } from "crypto";
import supabase from "./supabase";
import { LandmarkType, VerificationStatus } from "../types";

export class ProcessLandmarkError extends Error {
    statusCode: number;

    constructor(statusCode: number, message: string) {
        super(message);
        this.statusCode = statusCode;
    }
}

type LandmarkRow = {
    id: string;
    room_map_id: string;
    type: LandmarkType;
    label: string | null;
    confidence: number | null;
    source: "user" | "gemini";
    x: number;
    y: number;
    z: number;
    heading_degrees?: number | null;
    status: VerificationStatus;
    created_at: string;
};

type LandmarkVerificationRow = {
    id: string;
    landmark_id: string;
    verified_by: string;
    status: VerificationStatus;
    notes: string | null;
    created_at: string;
};

const LANDMARK_TYPES: LandmarkType[] = [
    "door",
    "wall",
    "stair",
    "elevator",
    "obstacle",
    "exit",
    "unknown",
];

const VERIFICATION_STATUSES: VerificationStatus[] = [
    "pending",
    "verified",
    "rejected",
];

type LandmarkHeadingColumnMode = "unknown" | "available" | "missing";
let landmarkHeadingColumnMode: LandmarkHeadingColumnMode = "unknown";

function toLandmarkType(value: unknown): LandmarkType {
    if (typeof value !== "string") {
        return "unknown";
    }

    const normalized = value.toLowerCase() as LandmarkType;
    return LANDMARK_TYPES.includes(normalized) ? normalized : "unknown";
}

function toVerificationStatus(value: unknown): VerificationStatus {
    if (typeof value !== "string") {
        return "pending";
    }

    const normalized = value.toLowerCase() as VerificationStatus;
    return VERIFICATION_STATUSES.includes(normalized) ? normalized : "pending";
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

function normalizeHeadingDegrees(value: unknown): number | null {
    if (typeof value !== "number" || !Number.isFinite(value)) {
        return null;
    }

    let normalized = value % 360;
    if (normalized < 0) {
        normalized += 360;
    }

    return normalized;
}

function isUndefinedColumnError(error: { code?: string; message?: string } | null | undefined): boolean {
    if (!error) {
        return false;
    }

    return (
        error.code === "PGRST204" ||
        error.code === "42703" ||
        /could not find the '.+' column of '.+'/i.test(error.message ?? "") ||
        /column\s+.+\s+does not exist/i.test(error.message ?? "")
    );
}

async function ensureMapExists(mapId: string): Promise<void> {
    const { data, error } = await supabase
        .from("room_maps")
        .select("id")
        .eq("id", mapId)
        .single();

    if (error || !data) {
        throw new ProcessLandmarkError(404, "Map not found");
    }
}

async function ensureLandmarkExists(landmarkId: string): Promise<LandmarkRow> {
    const { data, error } = await supabase
        .from("landmarks")
        .select("*")
        .eq("id", landmarkId)
        .single();

    if (error || !data) {
        throw new ProcessLandmarkError(404, "Landmark not found");
    }

    return data as LandmarkRow;
}

async function refreshLandmarkConfidence(landmarkId: string): Promise<void> {
    const { data, error } = await supabase
        .from("landmark_verifications")
        .select("status")
        .eq("landmark_id", landmarkId);

    if (error) {
        throw new ProcessLandmarkError(500, "Failed to refresh landmark confidence");
    }

    const rows = (data ?? []) as Array<{ status: VerificationStatus }>;
    const verifiedCount = rows.filter((row) => row.status === "verified").length;
    const rejectedCount = rows.filter((row) => row.status === "rejected").length;
    const totalSignals = verifiedCount + rejectedCount;

    const confidence = totalSignals > 0 ? verifiedCount / totalSignals : null;

    let status: VerificationStatus = "pending";
    if (verifiedCount > rejectedCount) {
        status = "verified";
    } else if (rejectedCount > verifiedCount) {
        status = "rejected";
    }

    const { error: updateError } = await supabase
        .from("landmarks")
        .update({
            confidence,
            status,
        })
        .eq("id", landmarkId);

    if (updateError) {
        throw new ProcessLandmarkError(500, "Failed to update landmark confidence");
    }
}

export async function createMapLandmark(input: {
    mapId: string;
    type: unknown;
    label?: unknown;
    x: unknown;
    y: unknown;
    z: unknown;
    headingDegrees?: unknown;
    source?: unknown;
    confidence?: unknown;
}): Promise<LandmarkRow> {
    await ensureMapExists(input.mapId);

    const headingDegrees = normalizeHeadingDegrees(input.headingDegrees);

    const payload: Record<string, unknown> = {
        room_map_id: input.mapId,
        type: toLandmarkType(input.type),
        label: typeof input.label === "string" ? input.label : null,
        confidence:
            typeof input.confidence === "number" && Number.isFinite(input.confidence)
                ? Math.max(0, Math.min(input.confidence, 1))
                : null,
        source: input.source === "gemini" ? "gemini" : "user",
        x: asNumber(input.x),
        y: asNumber(input.y),
        z: asNumber(input.z),
        status: "pending" as VerificationStatus,
    };

    if (headingDegrees !== null && landmarkHeadingColumnMode !== "missing") {
        payload.heading_degrees = headingDegrees;
    }

    let { data, error } = await supabase
        .from("landmarks")
        .insert(payload)
        .select("*")
        .single();

    if (error && payload.heading_degrees !== undefined && isUndefinedColumnError(error)) {
        landmarkHeadingColumnMode = "missing";
        delete payload.heading_degrees;

        const retry = await supabase
            .from("landmarks")
            .insert(payload)
            .select("*")
            .single();

        data = retry.data;
        error = retry.error;
    }

    if (!error && payload.heading_degrees !== undefined) {
        landmarkHeadingColumnMode = "available";
    }

    if (error || !data) {
        throw new ProcessLandmarkError(500, "Failed to create landmark");
    }

    return data as LandmarkRow;
}

export async function listMapLandmarks(mapId: string): Promise<LandmarkRow[]> {
    await ensureMapExists(mapId);

    const { data, error } = await supabase
        .from("landmarks")
        .select("*")
        .eq("room_map_id", mapId)
        .order("created_at", { ascending: true });

    if (error) {
        throw new ProcessLandmarkError(500, "Failed to fetch landmarks");
    }

    return (data ?? []) as LandmarkRow[];
}

export async function updateMapLandmark(input: {
    mapId: string;
    landmarkId: string;
    type?: unknown;
    label?: unknown;
    x?: unknown;
    y?: unknown;
    z?: unknown;
    headingDegrees?: unknown;
    source?: unknown;
}): Promise<LandmarkRow> {
    await ensureMapExists(input.mapId);

    const existing = await ensureLandmarkExists(input.landmarkId);
    if (existing.room_map_id !== input.mapId) {
        throw new ProcessLandmarkError(404, "Landmark not found for this map");
    }

    const patch: Record<string, unknown> = {};

    if (input.type !== undefined) {
        patch.type = toLandmarkType(input.type);
    }

    if (input.label !== undefined) {
        patch.label = typeof input.label === "string" ? input.label : null;
    }

    if (input.x !== undefined) {
        patch.x = asNumber(input.x, existing.x);
    }

    if (input.y !== undefined) {
        patch.y = asNumber(input.y, existing.y);
    }

    if (input.z !== undefined) {
        patch.z = asNumber(input.z, existing.z);
    }

    if (input.headingDegrees !== undefined && landmarkHeadingColumnMode !== "missing") {
        patch.heading_degrees = normalizeHeadingDegrees(input.headingDegrees);
    }

    if (input.source !== undefined) {
        patch.source = input.source === "gemini" ? "gemini" : "user";
    }

    const runUpdate = () => {
        return supabase
            .from("landmarks")
            .update(patch)
            .eq("id", input.landmarkId)
            .eq("room_map_id", input.mapId)
            .select("*")
            .single();
    };

    let { data, error } = await runUpdate();

    if (error && patch.heading_degrees !== undefined && isUndefinedColumnError(error)) {
        landmarkHeadingColumnMode = "missing";
        delete patch.heading_degrees;

        if (Object.keys(patch).length === 0) {
            return existing;
        }

        const retry = await runUpdate();
        data = retry.data;
        error = retry.error;
    }

    if (!error && patch.heading_degrees !== undefined) {
        landmarkHeadingColumnMode = "available";
    }

    if (error || !data) {
        throw new ProcessLandmarkError(500, "Failed to update landmark");
    }

    return data as LandmarkRow;
}

export async function deleteMapLandmark(input: {
    mapId: string;
    landmarkId: string;
}): Promise<void> {
    await ensureMapExists(input.mapId);

    const { error } = await supabase
        .from("landmarks")
        .delete()
        .eq("id", input.landmarkId)
        .eq("room_map_id", input.mapId);

    if (error) {
        throw new ProcessLandmarkError(500, "Failed to delete landmark");
    }
}

export async function verifyLandmark(input: {
    landmarkId: string;
    verifiedBy?: unknown;
    status: unknown;
    notes?: unknown;
}): Promise<{
    verification: LandmarkVerificationRow;
    confidenceUpdated: boolean;
}> {
    await ensureLandmarkExists(input.landmarkId);

    const verifiedBy =
        typeof input.verifiedBy === "string" && input.verifiedBy.trim().length > 0
            ? input.verifiedBy
            : randomUUID();

    const status = toVerificationStatus(input.status);

    const { data, error } = await supabase
        .from("landmark_verifications")
        .upsert(
            {
                landmark_id: input.landmarkId,
                verified_by: verifiedBy,
                status,
                notes: typeof input.notes === "string" ? input.notes : null,
                created_at: new Date().toISOString(),
            },
            { onConflict: "landmark_id,verified_by" },
        )
        .select("*")
        .single();

    if (error || !data) {
        throw new ProcessLandmarkError(500, "Failed to save verification");
    }

    await refreshLandmarkConfidence(input.landmarkId);

    return {
        verification: data as LandmarkVerificationRow,
        confidenceUpdated: true,
    };
}

export async function getLandmarkVerifications(
    landmarkId: string,
): Promise<LandmarkVerificationRow[]> {
    await ensureLandmarkExists(landmarkId);

    const { data, error } = await supabase
        .from("landmark_verifications")
        .select("*")
        .eq("landmark_id", landmarkId)
        .order("created_at", { ascending: false });

    if (error) {
        throw new ProcessLandmarkError(500, "Failed to fetch verifications");
    }

    return (data ?? []) as LandmarkVerificationRow[];
}

export async function getMapVerificationSummary(mapId: string): Promise<{
    mapId: string;
    totalLandmarks: number;
    pending: number;
    verified: number;
    rejected: number;
    averageConfidence: number | null;
    lowConfidenceCount: number;
}> {
    await ensureMapExists(mapId);

    const { data, error } = await supabase
        .from("landmarks")
        .select("status, confidence")
        .eq("room_map_id", mapId);

    if (error) {
        throw new ProcessLandmarkError(500, "Failed to fetch verification summary");
    }

    const landmarks = (data ?? []) as Array<{
        status: VerificationStatus;
        confidence: number | null;
    }>;

    const pending = landmarks.filter((landmark) => landmark.status === "pending").length;
    const verified = landmarks.filter((landmark) => landmark.status === "verified").length;
    const rejected = landmarks.filter((landmark) => landmark.status === "rejected").length;

    const confidenceValues = landmarks
        .map((landmark) => landmark.confidence)
        .filter((value): value is number => typeof value === "number");

    const averageConfidence =
        confidenceValues.length > 0
            ? confidenceValues.reduce((sum, value) => sum + value, 0) / confidenceValues.length
            : null;

    const lowConfidenceCount = confidenceValues.filter((value) => value < 0.6).length;

    return {
        mapId,
        totalLandmarks: landmarks.length,
        pending,
        verified,
        rejected,
        averageConfidence,
        lowConfidenceCount,
    };
}
