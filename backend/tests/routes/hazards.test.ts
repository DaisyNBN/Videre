import express from "express";
import request from "supertest";
import { beforeEach, describe, expect, it, vi } from "vitest";

const { mockInsertHazard, mockGetNearbyHazards } = vi.hoisted(() => ({
    mockInsertHazard: vi.fn(),
    mockGetNearbyHazards: vi.fn(),
}));

vi.mock("../../src/services/processHazard", () => ({
    insertHazard: mockInsertHazard,
    getNearbyHazards: mockGetNearbyHazards,
}));

vi.mock("../../src/services/logger", () => ({
    default: {
        error: vi.fn(),
        warn: vi.fn(),
        info: vi.fn(),
    },
}));

import hazardsRouter from "../../routes/hazards";

function createApp() {
    const app = express();
    app.use(express.json());
    app.use("/api/hazards", hazardsRouter);
    return app;
}

describe("hazards routes", () => {
    beforeEach(() => {
        mockInsertHazard.mockReset();
        mockGetNearbyHazards.mockReset();
    });

    it("reports hazard for valid payload", async () => {
        mockInsertHazard.mockResolvedValue({ success: true });

        const app = createApp();
        const response = await request(app).post("/api/hazards").send({
            lat: 37.77,
            lng: -122.42,
            type: "obstacle",
            description: "Blocked path",
        });

        expect(response.status).toBe(201);
        expect(response.body.success).toBe(true);
    });

    it("rejects hazard payload with invalid data", async () => {
        const app = createApp();

        const response = await request(app).post("/api/hazards").send({
            lat: "not-a-number",
            lng: -122.42,
            type: "obstacle",
        });

        expect(response.status).toBe(400);
        expect(response.body.success).toBe(false);
    });

    it("returns nearby hazards with count", async () => {
        mockGetNearbyHazards.mockResolvedValue([
            { id: 1, lat: 1, lng: 2, type: "obstacle", description: "one" },
        ]);

        const app = createApp();

        const response = await request(app).get("/api/hazards/nearby?lat=1&lng=2&radius=50");

        expect(response.status).toBe(200);
        expect(response.body.success).toBe(true);
        expect(response.body.data.count).toBe(1);
    });
});
