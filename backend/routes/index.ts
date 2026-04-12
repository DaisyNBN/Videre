import { Request, Response } from "express";
import navigationRouter from "./navigation";
import hazardRouter from "./hazards";
import scansRouter from "./scans";
import mapsRouter from "./maps";
import landmarksRouter from "./landmarks";
const router = require("express").Router();

router.use("/navigate", navigationRouter);
router.use("/hazards", hazardRouter);
router.use("/scans", scansRouter);
router.use("/maps", mapsRouter);
router.use("/landmarks", landmarksRouter);

// health check
router.get("/health", (req: Request, res: Response) => {
    res.json({
        status: "ok",
        timestamp: new Date().toISOString(),
        supabase: !!process.env.SUPABASE_URL,
        gemini: !!process.env.GEMINI_API_KEY,
    });
});

export default router;