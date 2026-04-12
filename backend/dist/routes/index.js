"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
const navigation_1 = __importDefault(require("./navigation"));
const hazards_1 = __importDefault(require("./hazards"));
const scans_1 = __importDefault(require("./scans"));
const maps_1 = __importDefault(require("./maps"));
const landmarks_1 = __importDefault(require("./landmarks"));
const router = require("express").Router();
router.use("/navigate", navigation_1.default);
router.use("/hazards", hazards_1.default);
router.use("/scans", scans_1.default);
router.use("/maps", maps_1.default);
router.use("/landmarks", landmarks_1.default);
// health check
router.get("/health", (req, res) => {
    res.json({
        status: "ok",
        timestamp: new Date().toISOString(),
        supabase: !!process.env.SUPABASE_URL,
        gemini: !!process.env.GEMINI_API_KEY,
    });
});
exports.default = router;
