import express from "express";
import request from "supertest";
import { beforeEach, describe, expect, it, vi } from "vitest";

const { mockGetLandmarkVerifications, mockVerifyLandmark } = vi.hoisted(() => ({
    mockGetLandmarkVerifications: vi.fn(),
    mockVerifyLandmark: vi.fn(),
}));

vi.mock("../../src/services/processLandmarks", () => ({
    ProcessLandmarkError: class ProcessLandmarkError extends Error {
        statusCode: number;

        constructor(statusCode: number, message: string) {
            super(message);
            this.statusCode = statusCode;
        }
    },
    getLandmarkVerifications: mockGetLandmarkVerifications,
    verifyLandmark: mockVerifyLandmark,
}));

vi.mock("../../src/services/logger", () => ({
    default: {
        error: vi.fn(),
        warn: vi.fn(),
        info: vi.fn(),
    },
}));

import landmarksRouter from "../../routes/landmarks";

function createApp() {
    const app = express();
    app.use(express.json());
    app.use("/api/landmarks", landmarksRouter);
    return app;
}

describe("landmarks routes", () => {
    beforeEach(() => {
        mockGetLandmarkVerifications.mockReset();
        mockVerifyLandmark.mockReset();
    });

    it("saves verification for valid payload", async () => {
        mockVerifyLandmark.mockResolvedValue({
            verification: {
                id: "v-1",
                landmark_id: "lm-1",
                status: "verified",
            },
            confidenceUpdated: true,
        });

        const app = createApp();

        const response = await request(app)
            .post("/api/landmarks/lm-1/verify")
            .send({
                status: "verified",
                notes: "Looks correct",
            });

        expect(response.status).toBe(201);
        expect(response.body.success).toBe(true);
        expect(mockVerifyLandmark).toHaveBeenCalledWith({
            landmarkId: "lm-1",
            verifiedBy: undefined,
            status: "verified",
            notes: "Looks correct",
        });
    });

    it("rejects verification payload when status is missing", async () => {
        const app = createApp();

        const response = await request(app)
            .post("/api/landmarks/lm-1/verify")
            .send({
                notes: "no status",
            });

        expect(response.status).toBe(400);
        expect(response.body.success).toBe(false);
    });

    it("returns verification history", async () => {
        mockGetLandmarkVerifications.mockResolvedValue([
            {
                id: "v-1",
                landmark_id: "lm-1",
                status: "verified",
                notes: null,
            },
        ]);

        const app = createApp();

        const response = await request(app).get("/api/landmarks/lm-1/verifications");

        expect(response.status).toBe(200);
        expect(response.body.success).toBe(true);
        expect(response.body.data).toHaveLength(1);
    });
});
