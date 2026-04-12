import { Request, Response } from "express";
import navigationRouter from "./navigation";
import hazardRouter from "./hazards";
import scansRouter from "./scans";
import mapsRouter from "./maps";
import landmarksRouter from "./landmarks";
import packageJson from "../package.json";
import { ApiResponse } from "../src/ApiResponse";
const router = require("express").Router();

router.use("/navigate", navigationRouter);
router.use("/navigation", navigationRouter);
router.use("/hazards", hazardRouter);
router.use("/scans", scansRouter);
router.use("/maps", mapsRouter);
router.use("/landmarks", landmarksRouter);

// health check
router.get("/health", (req: Request, res: Response) => {
    res.json(new ApiResponse(true, "Server is healthy", {
        timestamp: new Date().toISOString(),
        supabase: !!process.env.SUPABASE_URL,
        gemini: !!process.env.GEMINI_API_KEY,
    }));
});

router.get("/version", (_req: Request, res: Response) => {
    const version =
        typeof packageJson.version === "string" ? packageJson.version : "unknown";

    return res.json(
        new ApiResponse(true, "Version fetched", {
            name: packageJson.name,
            version,
            environment: process.env.NODE_ENV ?? "development",
            timestamp: new Date().toISOString(),
            features: {
                scanAnalysis: true,
                mapRoutes: true,
                landmarkVerification: true,
                navigationRoutes: true,
                mapContributions: true,
            },
        }),
    );
});

export default router;