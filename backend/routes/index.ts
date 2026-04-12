import { Request, Response } from "express";

const router = require("express").Router();

router.use("/navigate", require("./navigation"));
router.use("/hazards", require("./hazards"));
router.use("/scans", require("./scans"));
router.use("/maps", require("./maps"));
router.use("/landmarks", require("./landmarks"));

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