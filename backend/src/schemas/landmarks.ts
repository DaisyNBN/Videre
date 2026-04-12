import { z } from "zod";

export const landmarkIdParamsSchema = z.object({
    id: z.string().min(1),
});

export const verifyLandmarkBodySchema = z.object({
    verifiedBy: z.string().min(1).optional(),
    status: z.enum(["pending", "verified", "rejected"]),
    notes: z.string().optional(),
});

export type LandmarkIdParams = z.infer<typeof landmarkIdParamsSchema>;
export type VerifyLandmarkBody = z.infer<typeof verifyLandmarkBodySchema>;