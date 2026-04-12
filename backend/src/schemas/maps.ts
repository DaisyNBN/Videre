import { z } from "zod";

const landmarkTypeSchema = z.enum([
    "door",
    "wall",
    "stair",
    "elevator",
    "obstacle",
    "exit",
    "unknown",
]);

const vector3Schema = z.object({
    x: z.number().finite(),
    y: z.number().finite(),
    z: z.number().finite(),
});

const scanPointSchema = vector3Schema.extend({
    timestamp: z.number().finite().optional(),
});

const landmarkSchema = vector3Schema.extend({
    type: landmarkTypeSchema,
    label: z.string().optional(),
    confidence: z.number().finite().min(0).max(1).optional(),
    source: z.enum(["user", "gemini"]).optional(),
    anchorLat: z.number().finite().min(-90).max(90).optional(),
    anchorLng: z.number().finite().min(-180).max(180).optional(),
});

export const mapIdParamsSchema = z.object({
    id: z.string().min(1),
});

export const mapLandmarkParamsSchema = z.object({
    id: z.string().min(1),
    landmarkId: z.string().min(1),
});

export const mapCreateBodySchema = z
    .object({
        scanId: z.string().min(1).optional(),
        roomName: z.string().min(1).optional(),
        points: z.array(scanPointSchema).optional(),
        landmarks: z.array(landmarkSchema).optional(),
        createdBy: z.string().min(1).optional(),
    })
    .refine((value) => Boolean(value.scanId || value.roomName), {
        message: "Either scanId or roomName is required",
    });

export const mapListQuerySchema = z.object({
    roomName: z.string().optional(),
    version: z.coerce.number().int().optional(),
    limit: z.coerce.number().int().optional(),
    offset: z.coerce.number().int().optional(),
});

export const mapCreateLandmarkBodySchema = z.object({
    type: landmarkTypeSchema,
    label: z.string().optional(),
    x: z.number().finite(),
    y: z.number().finite(),
    z: z.number().finite(),
    source: z.enum(["user", "gemini"]).optional(),
    confidence: z.number().finite().min(0).max(1).optional(),
    anchorLat: z.number().finite().min(-90).max(90).optional(),
    anchorLng: z.number().finite().min(-180).max(180).optional(),
});

export const mapUpdateLandmarkBodySchema = z.object({
    type: landmarkTypeSchema.optional(),
    label: z.string().optional(),
    x: z.number().finite().optional(),
    y: z.number().finite().optional(),
    z: z.number().finite().optional(),
    source: z.enum(["user", "gemini"]).optional(),
    anchorLat: z.number().finite().min(-90).max(90).optional(),
    anchorLng: z.number().finite().min(-180).max(180).optional(),
});

export const mapAnchorNearbyQuerySchema = z.object({
    lat: z.coerce.number().finite(),
    lng: z.coerce.number().finite(),
    radius: z.coerce.number().finite().positive().optional(),
    roomName: z.string().optional(),
    type: landmarkTypeSchema.optional(),
});

export const mapContributionsCreateBodySchema = z.object({
    contributionType: z.string().min(1).optional(),
    type: z.string().min(1).optional(),
    payload: z.unknown().optional(),
    createdBy: z.string().min(1).optional(),
    status: z.string().min(1).optional(),
    notes: z.string().optional(),
    createVersionOnAccept: z.boolean().optional(),
});

export const mapContributionsListQuerySchema = z.object({
    status: z.string().min(1).optional(),
    limit: z.coerce.number().int().optional(),
    offset: z.coerce.number().int().optional(),
});

export type MapIdParams = z.infer<typeof mapIdParamsSchema>;
export type MapLandmarkParams = z.infer<typeof mapLandmarkParamsSchema>;
export type MapCreateBody = z.infer<typeof mapCreateBodySchema>;
export type MapListQuery = z.infer<typeof mapListQuerySchema>;
export type MapCreateLandmarkBody = z.infer<typeof mapCreateLandmarkBodySchema>;
export type MapUpdateLandmarkBody = z.infer<typeof mapUpdateLandmarkBodySchema>;
export type MapAnchorNearbyQuery = z.infer<typeof mapAnchorNearbyQuerySchema>;
export type MapContributionsCreateBody = z.infer<typeof mapContributionsCreateBodySchema>;
export type MapContributionsListQuery = z.infer<typeof mapContributionsListQuerySchema>;