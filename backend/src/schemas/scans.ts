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

const isoDateStringSchema = z
    .string()
    .min(1)
    .refine((value) => !Number.isNaN(Date.parse(value)), {
        message: "Must be a valid date string",
    });

const deviceInfoSchema = z.object({
    model: z.string().min(1),
    osVersion: z.string().min(1),
    appVersion: z.string().min(1),
});

const scanPointSchema = vector3Schema.extend({
    timestamp: z.number().finite().optional(),
    latitude: z.number().finite().optional(),
    longitude: z.number().finite().optional(),
    horizontalAccuracy: z.number().finite().nonnegative().optional(),
    verticalAccuracy: z.number().finite().nonnegative().optional(),
    headingDegrees: z.number().finite().min(0).max(360).optional(),
    trackingState: z.string().optional(),
});

const landmarkSchema = vector3Schema.extend({
    type: landmarkTypeSchema,
    label: z.string().optional(),
    confidence: z.number().finite().min(0).max(1).optional(),
    source: z.enum(["user", "gemini"]).optional(),
    timestamp: z.number().finite().optional(),
    headingDegrees: z.number().finite().min(0).max(360).optional(),
    latitude: z.number().finite().optional(),
    longitude: z.number().finite().optional(),
    horizontalAccuracy: z.number().finite().nonnegative().optional(),
    verticalAccuracy: z.number().finite().nonnegative().optional(),
});

const keyframeSchema = z.object({
    imageBase64: z.string().min(1),
    timestamp: z.number().finite(),
    cameraPose: vector3Schema,
});

const depthSampleSchema = z.object({
    timestamp: z.number().finite(),
    cameraPose: vector3Schema,
    depthUrl: z.string().min(1),
});

export const scanIdParamsSchema = z.object({
    id: z.string().min(1),
});

export const scanListQuerySchema = z.object({
    roomName: z.string().optional(),
    limit: z.coerce.number().int().optional(),
    offset: z.coerce.number().int().optional(),
});

export const scanCreateBodySchema = z.object({
    roomName: z.string().min(1),
    startedAt: isoDateStringSchema,
    endedAt: isoDateStringSchema,
    device: deviceInfoSchema,
    points: z.array(scanPointSchema).min(1),
    landmarks: z.array(landmarkSchema).min(1),
    keyframes: z.array(keyframeSchema),
    depthSamples: z.array(depthSampleSchema),
});

export type ScanIdParams = z.infer<typeof scanIdParamsSchema>;
export type ScanListQuery = z.infer<typeof scanListQuerySchema>;
export type ScanCreateBody = z.infer<typeof scanCreateBodySchema>;