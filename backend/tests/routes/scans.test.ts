import express from "express";
import request from "supertest";
import { beforeEach, describe, expect, it, vi } from "vitest";

const {
    mockAnalyzeScanById,
    mockCreateScan,
    mockGetScanById,
    mockGetScanDetections,
    mockGetScanProcessingStatus,
    mockListScans,
} = vi.hoisted(() => ({
    mockAnalyzeScanById: vi.fn(),
    mockCreateScan: vi.fn(),
    mockGetScanById: vi.fn(),
    mockGetScanDetections: vi.fn(),
    mockGetScanProcessingStatus: vi.fn(),
    mockListScans: vi.fn(),
}));

vi.mock("../../src/services/processScan", () => ({
    ProcessScanError: class ProcessScanError extends Error {
        statusCode: number;

        constructor(statusCode: number, message: string) {
            super(message);
            this.statusCode = statusCode;
        }
    },
    analyzeScanById: mockAnalyzeScanById,
    createScan: mockCreateScan,
    getScanById: mockGetScanById,
    getScanDetections: mockGetScanDetections,
    getScanProcessingStatus: mockGetScanProcessingStatus,
    listScans: mockListScans,
}));

vi.mock("../../src/services/logger", () => ({
    default: {
        error: vi.fn(),
        warn: vi.fn(),
        info: vi.fn(),
    },
}));

import scansRouter from "../../routes/scans";

function createApp() {
    const app = express();
    app.use(express.json());
    app.use("/api/scans", scansRouter);
    return app;
}

const validScanPayload = {
    roomName: "Lobby",
    startedAt: "2026-01-01T10:00:00.000Z",
    endedAt: "2026-01-01T10:01:00.000Z",
    device: {
        model: "iPhone",
        osVersion: "18.0",
        appVersion: "1.0.0",
    },
    points: [{ x: 0, y: 0, z: 0, timestamp: 1 }],
    landmarks: [{ type: "door", x: 0, y: 0, z: 0, source: "user" }],
    keyframes: [
        {
            imageBase64: "data:image/jpeg;base64,ZmFrZQ==",
            timestamp: 1,
            cameraPose: { x: 0, y: 0, z: 0 },
        },
    ],
    depthSamples: [
        {
            timestamp: 1,
            cameraPose: { x: 0, y: 0, z: 0 },
            depthUrl: "https://example.com/depth.bin",
        },
    ],
};

describe("scans routes", () => {
    beforeEach(() => {
        mockAnalyzeScanById.mockReset();
        mockCreateScan.mockReset();
        mockGetScanById.mockReset();
        mockGetScanDetections.mockReset();
        mockGetScanProcessingStatus.mockReset();
        mockListScans.mockReset();
    });

    it("lists scans for bootstrap", async () => {
        mockListScans.mockResolvedValue({
            scans: [
                {
                    id: "scan-1",
                    room_name: "Lobby",
                    started_at: "2026-01-01T10:00:00.000Z",
                    ended_at: "2026-01-01T10:01:00.000Z",
                    processing_status: "completed",
                },
            ],
            limit: 10,
            offset: 0,
        });

        const app = createApp();

        const response = await request(app)
            .get("/api/scans")
            .query({ roomName: "Lobby", limit: 10, offset: 0 });

        expect(response.status).toBe(200);
        expect(response.body.success).toBe(true);
        expect(response.body.data.scans).toHaveLength(1);
        expect(mockListScans).toHaveBeenCalledWith({
            roomName: "Lobby",
            limit: 10,
            offset: 0,
        });
    });

    it("rejects invalid scan payload", async () => {
        const app = createApp();

        const response = await request(app).post("/api/scans").send({
            startedAt: "2026-01-01T10:00:00.000Z",
        });

        expect(response.status).toBe(400);
        expect(response.body.success).toBe(false);
    });

    it("creates scan and triggers post-insert analysis", async () => {
        mockCreateScan.mockResolvedValue("scan-1");
        mockAnalyzeScanById.mockResolvedValue({
            scanId: "scan-1",
            processedLandmarks: [],
            processedObstacles: [],
            analyzedKeyframes: [],
        });

        const app = createApp();

        const response = await request(app).post("/api/scans").send(validScanPayload);

        expect(response.status).toBe(201);
        expect(response.body.success).toBe(true);
        expect(response.body.data.id).toBe("scan-1");
        expect(mockAnalyzeScanById).toHaveBeenCalledWith("scan-1", {
            keyframes: validScanPayload.keyframes,
            depthSamples: validScanPayload.depthSamples,
            existingLandmarks: validScanPayload.landmarks,
        });
    });

    it("returns detections for scan", async () => {
        mockGetScanDetections.mockResolvedValue({
            id: "scan-1",
            processingStatus: "ai-processed",
            detections: [],
            totalDetections: 0,
        });

        const app = createApp();

        const response = await request(app).get("/api/scans/scan-1/detections");

        expect(response.status).toBe(200);
        expect(response.body.success).toBe(true);
        expect(response.body.data.id).toBe("scan-1");
    });
});
