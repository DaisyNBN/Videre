import { z } from "zod";

export const reportHazardBodySchema = z.object({
    lat: z.number().finite(),
    lng: z.number().finite(),
    type: z.string().min(1),
    description: z.string().optional(),
});

export const nearbyHazardsQuerySchema = z.object({
    lat: z.coerce.number().finite(),
    lng: z.coerce.number().finite(),
    radius: z.coerce.number().finite().positive().max(1000).optional().default(100),
});

export type ReportHazardBody = z.infer<typeof reportHazardBodySchema>;
export type NearbyHazardsQuery = z.infer<typeof nearbyHazardsQuerySchema>;
