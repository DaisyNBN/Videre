import { Request, Response } from "express";
import { ApiResponse } from "../src/ApiResponse";
import { validateBody, validateParams } from "../src/middleware/validate";
import {
    scanCreateBodySchema,
    scanCreateWithRouteBodySchema,
    scanIdParamsSchema,
    ScanCreateBody,
    ScanCreateWithRouteBody,
    ScanIdParams,
} from "../src/schemas/scans";
import logger from "../src/services/logger";
import {
    ProcessScanError,
    analyzeScanById,
    createScan,
    getScanById,
    getScanDetections,
    getScanProcessingStatus,
} from "../src/services/processScan";
import {
    ScanRouteError,
    createRouteFromScanWaypoints,
} from "../src/services/processScanRoute";

const router = require("express").Router();

// POST /api/scans
// - Create a new scan upload record.
// - Accept`ScanUploadRequest` payload (`roomName`, scan timing/device data, points, landmarks, keyframes, depthSamples).
router.post('/', validateBody(scanCreateBodySchema), async (req: Request, res: Response) => {
    const {
        roomName,
        startedAt,
        endedAt,
        device,
        points,
        landmarks,
        keyframes,
        depthSamples,
    } = req.body as ScanCreateBody;

    let scanId: string;
    try {
        scanId = await createScan({
            roomName,
            startedAt,
            endedAt,
            device,
            points,
            landmarks,
            keyframes,
            depthSamples,
        });
    } catch (err) {
        if (err instanceof ProcessScanError) {
            return res.status(err.statusCode).json(new ApiResponse(false, err.message));
        }

        logger.error('Unexpected error creating scan: %o', err);
        return res.status(500).json(new ApiResponse(false, 'Failed to create scan'));
    }

    try {
        await analyzeScanById(scanId, {
            keyframes,
            depthSamples,
            existingLandmarks: landmarks,
        });
    } catch (analysisError) {
        logger.error('Post-insert analysis failed for scan %s: %o', scanId, analysisError);
    }

    return res.status(201).json(new ApiResponse(true, 'Scan created', { id: scanId }));
});

// POST /api/scans/with-route
// - Create a new scan with immediate route creation from collected LiDAR waypoints.
// - Records coordinates during scanning for the most accurate route data.
// - Supports rapid LiDAR sampling to build accurate indoor routes.
router.post('/with-route', validateBody(scanCreateWithRouteBodySchema), async (req: Request, res: Response) => {
    const {
        roomName,
        startedAt,
        endedAt,
        device,
        points,
        landmarks,
        keyframes,
        depthSamples,
        waypoints,
        createRouteImmediately,
    } = req.body as ScanCreateWithRouteBody;

    let scanId: string;
    try {
        // First create the scan as normal
        scanId = await createScan({
            roomName,
            startedAt,
            endedAt,
            device,
            points,
            landmarks,
            keyframes,
            depthSamples,
        });

        logger.info('Scan created: %s with waypoint-based route', scanId);
    } catch (err) {
        if (err instanceof ProcessScanError) {
            return res.status(err.statusCode).json(new ApiResponse(false, err.message));
        }

        logger.error('Unexpected error creating scan: %o', err);
        return res.status(500).json(new ApiResponse(false, 'Failed to create scan'));
    }

    // Start analysis in background (non-blocking)
    try {
        await analyzeScanById(scanId, {
            keyframes,
            depthSamples,
            existingLandmarks: landmarks,
        });
    } catch (analysisError) {
        logger.error('Post-insert analysis failed for scan %s: %o', scanId, analysisError);
    }

    let routeResult = null;

    // Create route immediately if requested (default true)
    if (createRouteImmediately) {
        try {
            // For now, use a generated mapId based on room name and scan
            // In a full implementation, this would link to an existing or newly created map
            const mapId = `map-${roomName.toLowerCase().replace(/\s+/g, '-')}-${scanId.substring(0, 8)}`;

            const routeData = await createRouteFromScanWaypoints(
                scanId,
                mapId,
                roomName,
                waypoints
            );

            routeResult = routeData;

            logger.info(
                'Route created during scan: routeId=%s, mapId=%s, waypoints=%d',
                routeData.routeId,
                routeData.mapId,
                routeData.waypointCount
            );
        } catch (routeErr) {
            if (routeErr instanceof ScanRouteError) {
                logger.warn('Failed to create route for scan %s: %s', scanId, routeErr.message);
                // Non-fatal: route creation failed but scan succeeded
            } else {
                logger.error('Unexpected error creating route: %o', routeErr);
            }
        }
    }

    return res.status(201).json(
        new ApiResponse(true, 'Scan created with route from waypoints', {
            scanId,
            route: routeResult,
        })
    );
});

// GET /api/scans/:scanId
// - Return scan details and metadata.
router.get('/:id', validateParams(scanIdParamsSchema), async (req: Request, res: Response) => {
    const { id: scanId } = req.params as ScanIdParams;

    try {
        const data = await getScanById(scanId);
        return res.json(new ApiResponse(true, 'Scan fetched', data));
    } catch (err) {
        if (err instanceof ProcessScanError) {
            return res.status(err.statusCode).json(new ApiResponse(false, err.message));
        }

        logger.error('Unexpected error fetching scan %s: %o', scanId, err);
        return res.status(500).json(new ApiResponse(false, 'Failed to fetch scan'));
    }
});

// GET / api / scans /: scanId / processing
// - Return processing status (`uploaded`, `ai - processing`, `graph - built`, `failed`).
router.get('/:id/processing', validateParams(scanIdParamsSchema), async (req: Request, res: Response) => {
    const { id: scanId } = req.params as ScanIdParams;

    try {
        const data = await getScanProcessingStatus(scanId);
        return res.json(new ApiResponse(true, 'Processing status fetched', data));
    } catch (err) {
        if (err instanceof ProcessScanError) {
            return res.status(err.statusCode).json(new ApiResponse(false, err.message));
        }

        logger.error('Unexpected error fetching scan processing status for %s: %o', scanId, err);
        return res.status(500).json(new ApiResponse(false, 'Failed to fetch processing status'));
    }
});

// POST /api/scans/:scanId/analyze
// - Trigger AI analysis for scan keyframes.
router.post('/:id/analyze', validateParams(scanIdParamsSchema), async (req: Request, res: Response) => {
    const { id: scanId } = req.params as ScanIdParams;

    try {
        const result = await analyzeScanById(scanId);
        return res.json(new ApiResponse(true, 'AI analysis completed', result));
    } catch (err) {
        if (err instanceof ProcessScanError) {
            return res.status(err.statusCode).json(new ApiResponse(false, err.message));
        }

        logger.error('Unexpected error during scan analysis for %s: %o', scanId, err);
        return res.status(500).json(new ApiResponse(false, 'Failed to analyze scan keyframes'));
    }
});

// GET /api/scans/:scanId/detections
// - Return AIObjectDetection[] with confidence and optional bounding box.
router.get('/:id/detections', validateParams(scanIdParamsSchema), async (req: Request, res: Response) => {
    const { id: scanId } = req.params as ScanIdParams;

    try {
        const detectionsData = await getScanDetections(scanId);
        return res.json(new ApiResponse(true, 'Detections fetched', detectionsData));
    } catch (err) {
        if (err instanceof ProcessScanError) {
            return res.status(err.statusCode).json(new ApiResponse(false, err.message));
        }

        logger.error('Error during detection fetch for %s: %o', scanId, err);
        return res.status(500).json(new ApiResponse(false, 'Failed to fetch detections'));
    }
});

export default router;
