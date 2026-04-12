import express from "express";
import request from "supertest";
import { beforeEach, describe, expect, it, vi } from "vitest";

const {
    mockGenerateNavigationRoute,
    mockGenerateNavigationRouteFromCoordinates,
    mockGenerateNavigationRouteToRoom,
    mockGetNavigationInstruction,
    mockRerouteNavigation,
} = vi.hoisted(() => ({
    mockGenerateNavigationRoute: vi.fn(),
    mockGenerateNavigationRouteFromCoordinates: vi.fn(),
    mockGenerateNavigationRouteToRoom: vi.fn(),
    mockGetNavigationInstruction: vi.fn(),
    mockRerouteNavigation: vi.fn(),
}));

vi.mock("../../src/services/processNavigation", () => ({
    NavigationError: class NavigationError extends Error {
        statusCode: number;

        constructor(statusCode: number, message: string) {
            super(message);
            this.statusCode = statusCode;
        }
    },
    generateNavigationRoute: mockGenerateNavigationRoute,
    generateNavigationRouteFromCoordinates: mockGenerateNavigationRouteFromCoordinates,
    generateNavigationRouteToRoom: mockGenerateNavigationRouteToRoom,
    getNavigationInstruction: mockGetNavigationInstruction,
    rerouteNavigation: mockRerouteNavigation,
}));

vi.mock("../../src/services/logger", () => ({
    default: {
        error: vi.fn(),
        warn: vi.fn(),
        info: vi.fn(),
    },
}));

import navigationRouter from "../../routes/navigation";

function createApp() {
    const app = express();
    app.use(express.json());
    app.use("/api/navigation", navigationRouter);
    return app;
}

describe("navigation routes", () => {
    beforeEach(() => {
        mockGenerateNavigationRoute.mockReset();
        mockGenerateNavigationRouteFromCoordinates.mockReset();
        mockGenerateNavigationRouteToRoom.mockReset();
        mockGetNavigationInstruction.mockReset();
        mockRerouteNavigation.mockReset();
    });

    it("returns instruction for valid instructions payload", async () => {
        mockGetNavigationInstruction.mockResolvedValue({
            instruction: "Continue straight",
            urgency: "low",
            haptic_pattern: "single_tap",
            next_checkpoint: null,
            distance_to_next_m: null,
            fallback_used: false,
        });

        const app = createApp();

        const response = await request(app)
            .post("/api/navigation/instructions")
            .send({
                routeId: "route-123",
                location: { lat: 12.1, lng: 34.2 },
                headingDegrees: 90,
                obstacles: [],
                speed: "walking",
            });

        expect(response.status).toBe(200);
        expect(response.body.success).toBe(true);
        expect(response.body.data.instruction).toBe("Continue straight");
    });

    it("accepts map-position in instructions payload", async () => {
        mockGetNavigationInstruction.mockResolvedValue({
            instruction: "Proceed to Room 201",
            urgency: "low",
            haptic_pattern: "single_tap",
            next_checkpoint: "Room 201",
            distance_to_next_m: 3,
            fallback_used: false,
        });

        const app = createApp();

        const response = await request(app)
            .post("/api/navigation/instructions")
            .send({
                routeId: "route-123",
                location: { lat: 12.1, lng: 34.2 },
                mapPosition: { x: 1.25, y: -0.4, z: 0.9 },
                headingDegrees: 90,
                obstacles: [],
                speed: "walking",
            });

        expect(response.status).toBe(200);
        expect(response.body.success).toBe(true);
        expect(mockGetNavigationInstruction).toHaveBeenCalledWith(
            expect.objectContaining({
                route_id: "route-123",
                map_position: { x: 1.25, y: -0.4, z: 0.9 },
            }),
        );
    });

    it("accepts speedMps in instructions payload", async () => {
        mockGetNavigationInstruction.mockResolvedValue({
            instruction: "Slight right",
            urgency: "medium",
            haptic_pattern: "double_tap",
            next_checkpoint: "Room 204",
            distance_to_next_m: 5,
            fallback_used: true,
        });

        const app = createApp();

        const response = await request(app)
            .post("/api/navigation/instructions")
            .send({
                routeId: "route-123",
                location: { lat: 12.1, lng: 34.2 },
                headingDegrees: 90,
                speed: "walking",
                speedMps: 1.35,
                obstacles: [],
            });

        expect(response.status).toBe(200);
        expect(response.body.success).toBe(true);
        expect(mockGetNavigationInstruction).toHaveBeenCalledWith(
            expect.objectContaining({
                speed_mps: 1.35,
            }),
        );
    });

    it("returns 400 for invalid instructions payload", async () => {
        const app = createApp();

        const response = await request(app)
            .post("/api/navigation/instructions")
            .send({
                routeId: "route-123",
                obstacles: [],
            });

        expect(response.status).toBe(400);
        expect(response.body.success).toBe(false);
    });

    it("generates route for valid routes payload", async () => {
        mockGenerateNavigationRoute.mockResolvedValue({
            routeId: "route-abc",
            mapId: "map-1",
            startNodeId: "node-a",
            endNodeId: "node-b",
            nodeIds: ["node-a", "node-b"],
            checkpoints: [
                {
                    order: 1,
                    nodeId: "node-a",
                    label: "start",
                    x: 0,
                    y: 0,
                    z: 0,
                },
            ],
            checkpointStorage: "in-memory",
        });

        const app = createApp();

        const response = await request(app)
            .post("/api/navigation/routes")
            .send({
                mapId: "map-1",
                startNodeId: "node-a",
                endNodeId: "node-b",
            });

        expect(response.status).toBe(201);
        expect(response.body.success).toBe(true);
        expect(response.body.data.routeId).toBe("route-abc");
    });

    it("generates route from coordinates", async () => {
        mockGenerateNavigationRouteFromCoordinates.mockResolvedValue({
            routeId: "route-xyz",
            mapId: "map-1",
            startNodeId: "node-a",
            endNodeId: "node-c",
            nodeIds: ["node-a", "node-b", "node-c"],
            checkpoints: [
                {
                    order: 1,
                    nodeId: "node-a",
                    label: "start",
                    x: 0,
                    y: 0,
                    z: 0,
                },
            ],
            checkpointStorage: "in-memory",
            resolvedFromCoordinates: {
                startDistance: 0.124,
                endDistance: 0.312,
            },
        });

        const app = createApp();

        const response = await request(app)
            .post("/api/navigation/routes/from-coordinates")
            .send({
                mapId: "map-1",
                start: { x: 0.1, y: 0.2 },
                end: { x: 3.5, y: 1.4 },
            });

        expect(response.status).toBe(201);
        expect(response.body.success).toBe(true);
        expect(response.body.data.routeId).toBe("route-xyz");
        expect(mockGenerateNavigationRouteFromCoordinates).toHaveBeenCalledWith({
            mapId: "map-1",
            start: { x: 0.1, y: 0.2 },
            end: { x: 3.5, y: 1.4 },
            blockedNodeIds: [],
        });
    });

    it("generates route to destination room", async () => {
        mockGenerateNavigationRouteToRoom.mockResolvedValue({
            routeId: "route-room-1",
            mapId: "map-1",
            startNodeId: "node-a",
            endNodeId: "node-r201",
            nodeIds: ["node-a", "node-r201"],
            checkpoints: [
                {
                    order: 1,
                    nodeId: "node-a",
                    label: "start",
                    x: 0,
                    y: 0,
                    z: 0,
                },
            ],
            checkpointStorage: "in-memory",
            destination: {
                landmarkId: "lm-201",
                label: "Room 201",
                type: "door",
                status: "verified",
                confidence: 0.94,
            },
            resolvedFromCoordinates: {
                startDistance: 0.114,
                destinationDistance: 0.208,
            },
        });

        const app = createApp();

        const response = await request(app)
            .post("/api/navigation/routes/to-room")
            .send({
                mapId: "map-1",
                start: { x: 0.1, y: 0.2, z: 0.0 },
                destinationLabel: "Room 201",
            });

        expect(response.status).toBe(201);
        expect(response.body.success).toBe(true);
        expect(response.body.data.routeId).toBe("route-room-1");
        expect(mockGenerateNavigationRouteToRoom).toHaveBeenCalledWith({
            mapId: "map-1",
            start: { x: 0.1, y: 0.2, z: 0.0 },
            destinationLabel: "Room 201",
            blockedNodeIds: [],
        });
    });
});
