import { z } from "zod";

const obstacleSchema = z.object({
    label: z.string().min(1),
    position: z.enum(["left", "center", "right"]),
    distance_estimate: z.enum(["near", "mid", "far"]),
});

const locationSchema = z.object({
    lat: z.number().finite(),
    lng: z.number().finite(),
});

const coordinateSchema = z.object({
    x: z.number().finite(),
    y: z.number().finite(),
    z: z.number().finite().optional(),
});

export const navigationInstructionBodySchema = z.object({
    route_id: z.string().optional(),
    routeId: z.string().optional(),
    location: locationSchema,
    heading_degrees: z.number().finite().optional(),
    headingDegrees: z.number().finite().optional(),
    obstacles: z.array(obstacleSchema).optional().default([]),
    speed: z.enum(["walking", "stopped"]).optional().default("walking"),
});

export const navigationRouteBodySchema = z.object({
    mapId: z.string().min(1),
    startNodeId: z.string().min(1),
    endNodeId: z.string().min(1),
    blockedNodeIds: z.array(z.string().min(1)).optional().default([]),
});

export const navigationRouteFromCoordinatesBodySchema = z.object({
    mapId: z.string().min(1),
    start: coordinateSchema,
    end: coordinateSchema,
    blockedNodeIds: z.array(z.string().min(1)).optional().default([]),
});

export const navigationRouteToRoomBodySchema = z.object({
    mapId: z.string().min(1),
    start: coordinateSchema,
    destinationLabel: z.string().min(1),
    blockedNodeIds: z.array(z.string().min(1)).optional().default([]),
});

export const navigationRerouteBodySchema = navigationRouteBodySchema.extend({
    obstacleNodeIds: z.array(z.string().min(1)).optional().default([]),
    reason: z.string().optional(),
});

export type NavigationInstructionBody = z.infer<typeof navigationInstructionBodySchema>;
export type NavigationRouteBody = z.infer<typeof navigationRouteBodySchema>;
export type NavigationRouteFromCoordinatesBody =
    z.infer<typeof navigationRouteFromCoordinatesBodySchema>;
export type NavigationRouteToRoomBody =
    z.infer<typeof navigationRouteToRoomBodySchema>;
export type NavigationRerouteBody = z.infer<typeof navigationRerouteBodySchema>;
