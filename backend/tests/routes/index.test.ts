import express, { Request, Response, Router } from "express";
import request from "supertest";
import { describe, expect, it, vi } from "vitest";

function createStubRouter(): Router {
    const router = Router();
    router.get("/__stub", (_req: Request, res: Response) => {
        res.json({ ok: true });
    });
    return router;
}

vi.mock("../../routes/navigation", () => ({
    default: createStubRouter(),
}));

vi.mock("../../routes/hazards", () => ({
    default: createStubRouter(),
}));

vi.mock("../../routes/scans", () => ({
    default: createStubRouter(),
}));

vi.mock("../../routes/maps", () => ({
    default: createStubRouter(),
}));

vi.mock("../../routes/landmarks", () => ({
    default: createStubRouter(),
}));

import apiRouter from "../../routes/index";

describe("index routes", () => {
    it("returns app version metadata", async () => {
        const app = express();
        app.use("/api", apiRouter);

        const response = await request(app).get("/api/version");

        expect(response.status).toBe(200);
        expect(response.body.success).toBe(true);
        expect(response.body.data).toHaveProperty("version");
        expect(response.body.data).toHaveProperty("features.mapContributions", true);
    });
});
