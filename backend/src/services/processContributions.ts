import { randomUUID } from "crypto";
import supabase from "./supabase";
import { createMapVersion } from "./processMap";

export class ProcessContributionError extends Error {
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

type ContributionStatus = "pending" | "accepted" | "rejected";

function isUuid(value: string): boolean {
    return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

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

function normalizeStatus(value: unknown): ContributionStatus {
    if (typeof value !== "string") {
        return "pending";
    }

    if (value === "accepted" || value === "rejected" || value === "pending") {
        return value;
    }

    return "pending";
}

async function ensureMapExists(mapId: string): Promise<void> {
    const { data, error } = await supabase
        .from("room_maps")
        .select("id")
        .eq("id", mapId)
        .single();

    if (error || !data) {
        throw new ProcessContributionError(404, "Map not found");
    }
}

export async function createMapContribution(input: {
    mapId: string;
    contributionType: unknown;
    payload?: unknown;
    createdBy?: unknown;
    status?: unknown;
    notes?: unknown;
    createVersionOnAccept?: unknown;
}): Promise<{
    contribution: Record<string, unknown>;
    versionCreated: {
        id: string;
        version: number;
        sourceMapId: string;
    } | null;
}> {
    await ensureMapExists(input.mapId);

    const contributionType =
        typeof input.contributionType === "string" && input.contributionType.trim().length > 0
            ? input.contributionType.trim()
            : "generic";

    const status = normalizeStatus(input.status);

    const rawCreatedBy =
        typeof input.createdBy === "string" ? input.createdBy.trim() : "";
    const createdBy = rawCreatedBy.length > 0 && isUuid(rawCreatedBy)
        ? rawCreatedBy
        : randomUUID();

    const baseContributionPayload =
        input.payload !== undefined && input.payload !== null
            ? input.payload
            : {};

    let normalizedContributionPayload: unknown = baseContributionPayload;
    if (
        rawCreatedBy.length > 0 &&
        !isUuid(rawCreatedBy) &&
        typeof baseContributionPayload === "object" &&
        baseContributionPayload !== null &&
        !Array.isArray(baseContributionPayload)
    ) {
        normalizedContributionPayload = {
            ...(baseContributionPayload as Record<string, unknown>),
            submitted_by_label: rawCreatedBy,
        };
    }

    const payload = {
        map_id: input.mapId,
        contribution_type: contributionType,
        payload: normalizedContributionPayload,
        status,
        created_by: createdBy,
        notes: typeof input.notes === "string" ? input.notes : null,
        created_at: new Date().toISOString(),
        resolved_at: status === "pending" ? null : new Date().toISOString(),
    };

    const { data, error } = await supabase
        .from("map_contributions")
        .insert(payload)
        .select("*")
        .single();

    if (error) {
        if (isMissingSchemaError(error)) {
            throw new ProcessContributionError(
                501,
                "map_contributions table is missing. Run docs/map-contributions-schema.sql first.",
            );
        }

        throw new ProcessContributionError(500, "Failed to create contribution");
    }

    let versionCreated: {
        id: string;
        version: number;
        sourceMapId: string;
    } | null = null;

    const createVersionOnAccept = input.createVersionOnAccept === true;
    if (status === "accepted" && createVersionOnAccept) {
        const version = await createMapVersion(input.mapId);
        versionCreated = {
            id: version.id,
            version: version.version,
            sourceMapId: version.sourceMapId,
        };
    }

    return {
        contribution: (data ?? {}) as Record<string, unknown>,
        versionCreated,
    };
}

export async function listMapContributions(input: {
    mapId: string;
    status?: unknown;
    limit?: unknown;
    offset?: unknown;
}): Promise<{
    contributions: Array<Record<string, unknown>>;
    limit: number;
    offset: number;
}> {
    await ensureMapExists(input.mapId);

    const limitRaw = typeof input.limit === "number" ? input.limit : 25;
    const offsetRaw = typeof input.offset === "number" ? input.offset : 0;
    const limit = Math.max(1, Math.min(100, Math.floor(limitRaw)));
    const offset = Math.max(0, Math.floor(offsetRaw));

    let query = supabase
        .from("map_contributions")
        .select("*")
        .eq("map_id", input.mapId)
        .order("created_at", { ascending: false })
        .range(offset, offset + limit - 1);

    const status = normalizeStatus(input.status);
    if (typeof input.status === "string") {
        query = query.eq("status", status);
    }

    const { data, error } = await query;

    if (error) {
        if (isMissingSchemaError(error)) {
            throw new ProcessContributionError(
                501,
                "map_contributions table is missing. Run docs/map-contributions-schema.sql first.",
            );
        }

        throw new ProcessContributionError(500, "Failed to list contributions");
    }

    return {
        contributions: (data ?? []) as Array<Record<string, unknown>>,
        limit,
        offset,
    };
}
