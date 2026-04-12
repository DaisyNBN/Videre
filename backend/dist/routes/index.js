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
const package_json_1 = __importDefault(require("../package.json"));
const ApiResponse_1 = require("../src/ApiResponse");
const router = require("express").Router();
router.use("/navigate", navigation_1.default);
router.use("/navigation", navigation_1.default);
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
router.get("/version", (_req, res) => {
    const version = typeof package_json_1.default.version === "string" ? package_json_1.default.version : "unknown";
    return res.json(new ApiResponse_1.ApiResponse(true, "Version fetched", {
        name: package_json_1.default.name,
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
    }));
});
exports.default = router;
