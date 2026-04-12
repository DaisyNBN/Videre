import express from "express";
import request from "supertest";
import { beforeEach, describe, expect, it, vi } from "vitest";

const {
    mockCreateMap,
    mockCreateMapNode,
    mockCreateMapVersion,
    mockGetMapById,
    mockGetMapGraph,
    mockListMaps,
    mockCreateMapLandmark,
    mockDeleteMapLandmark,
    mockGetMapVerificationSummary,
    mockListMapLandmarks,
    mockUpdateMapLandmark,
    mockCreateMapContribution,
    mockListMapContributions,
} = vi.hoisted(() => ({
    mockCreateMap: vi.fn(),
    mockCreateMapNode: vi.fn(),
    mockCreateMapVersion: vi.fn(),
    mockGetMapById: vi.fn(),
    mockGetMapGraph: vi.fn(),
    mockListMaps: vi.fn(),
    mockCreateMapLandmark: vi.fn(),
    mockDeleteMapLandmark: vi.fn(),
    mockGetMapVerificationSummary: vi.fn(),
    mockListMapLandmarks: vi.fn(),
    mockUpdateMapLandmark: vi.fn(),
    mockCreateMapContribution: vi.fn(),
    mockListMapContributions: vi.fn(),
}));

vi.mock("../../src/services/processMap", () => ({
    ProcessMapError: class ProcessMapError extends Error {
        statusCode: number;

        constructor(statusCode: number, message: string) {
            super(message);
            this.statusCode = statusCode;
        }
    },
    createMap: mockCreateMap,
    createMapNode: mockCreateMapNode,
    createMapVersion: mockCreateMapVersion,
    getMapById: mockGetMapById,
    getMapGraph: mockGetMapGraph,
    listMaps: mockListMaps,
}));

vi.mock("../../src/services/processLandmarks", () => ({
    ProcessLandmarkError: class ProcessLandmarkError extends Error {
        statusCode: number;

        constructor(statusCode: number, message: string) {
            super(message);
            this.statusCode = statusCode;
        }
    },
    createMapLandmark: mockCreateMapLandmark,
    deleteMapLandmark: mockDeleteMapLandmark,
    getMapVerificationSummary: mockGetMapVerificationSummary,
    listMapLandmarks: mockListMapLandmarks,
    updateMapLandmark: mockUpdateMapLandmark,
}));

vi.mock("../../src/services/processContributions", () => ({
    ProcessContributionError: class ProcessContributionError extends Error {
        statusCode: number;

        constructor(statusCode: number, message: string) {
            super(message);
            this.statusCode = statusCode;
        }
    },
    createMapContribution: mockCreateMapContribution,
    listMapContributions: mockListMapContributions,
}));

vi.mock("../../src/services/logger", () => ({
    default: {
        error: vi.fn(),
        warn: vi.fn(),
        info: vi.fn(),
    },
}));

import mapsRouter from "../../routes/maps";

function createApp() {
    const app = express();
    app.use(express.json());
    app.use("/api/maps", mapsRouter);
    return app;
}

describe("maps routes", () => {
    beforeEach(() => {
        mockCreateMap.mockReset();
        mockCreateMapNode.mockReset();
        mockCreateMapVersion.mockReset();
        mockGetMapById.mockReset();
        mockGetMapGraph.mockReset();
        mockListMaps.mockReset();
        mockCreateMapLandmark.mockReset();
        mockDeleteMapLandmark.mockReset();
        mockGetMapVerificationSummary.mockReset();
        mockListMapLandmarks.mockReset();
        mockUpdateMapLandmark.mockReset();
        mockCreateMapContribution.mockReset();
        mockListMapContributions.mockReset();
    });

    it("rejects map creation when scanId and roomName are both missing", async () => {
        const app = createApp();

        const response = await request(app).post("/api/maps").send({});

        expect(response.status).toBe(400);
        expect(response.body.success).toBe(false);
    });

    it("creates a map when payload is valid", async () => {
        mockCreateMap.mockResolvedValue({
            id: "map-1",
            roomName: "Lobby",
            version: 1,
            nodeCount: 10,
            edgeCount: 9,
            sourceScanId: null,
        });

        const app = createApp();

        const response = await request(app).post("/api/maps").send({
            roomName: "Lobby",
            points: [{ x: 0, y: 0, z: 0 }],
            landmarks: [],
        });

        expect(response.status).toBe(201);
        expect(response.body.success).toBe(true);
        expect(response.body.data.id).toBe("map-1");
    });

    it("lists maps and coerces numeric query params", async () => {
        mockListMaps.mockResolvedValue({
            maps: [],
            limit: 10,
            offset: 2,
        });

        const app = createApp();

        const response = await request(app).get("/api/maps?limit=10&offset=2&version=3");

        expect(response.status).toBe(200);
        expect(response.body.success).toBe(true);
        expect(mockListMaps).toHaveBeenCalledWith({
            roomName: undefined,
            version: 3,
            limit: 10,
            offset: 2,
        });
    });

    it("creates a new map version", async () => {
        mockCreateMapVersion.mockResolvedValue({
            id: "map-2",
            roomName: "Lobby",
            version: 2,
            sourceMapId: "map-1",
            nodeCount: 12,
            edgeCount: 11,
        });

        const app = createApp();

        const response = await request(app).post("/api/maps/map-1/version").send({});

        expect(response.status).toBe(201);
        expect(response.body.success).toBe(true);
        expect(response.body.data.id).toBe("map-2");
    });

    it("creates a map node and forwards connection settings", async () => {
        mockCreateMapNode.mockResolvedValue({
            id: "node-1",
            mapId: "map-1",
            type: "path",
            label: "North entrance",
            x: 1.25,
            y: 3.5,
            z: 0,
            connectedToNodeId: "node-0",
            connectedDistanceMeters: 2.8,
        });

        const app = createApp();

        const response = await request(app).post("/api/maps/map-1/nodes").send({
            type: "path",
            label: "North entrance",
            x: 1.25,
            y: 3.5,
            z: 0,
            autoConnect: true,
            maxConnectionDistanceMeters: 9,
        });

        expect(response.status).toBe(201);
        expect(response.body.success).toBe(true);
        expect(response.body.data.id).toBe("node-1");
        expect(mockCreateMapNode).toHaveBeenCalledWith({
            mapId: "map-1",
            type: "path",
            label: "North entrance",
            x: 1.25,
            y: 3.5,
            z: 0,
            autoConnect: true,
            maxConnectionDistanceMeters: 9,
        });
    });

    it("lists map contributions with validated query", async () => {
        mockListMapContributions.mockResolvedValue({
            contributions: [],
            limit: 5,
            offset: 0,
        });

        const app = createApp();

        const response = await request(app).get(
            "/api/maps/map-1/contributions?status=pending&limit=5&offset=0",
        );

        expect(response.status).toBe(200);
        expect(response.body.success).toBe(true);
        expect(mockListMapContributions).toHaveBeenCalledWith({
            mapId: "map-1",
            status: "pending",
            limit: 5,
            offset: 0,
        });
    });
});
