import { Request, Response } from "express";
import { ApiResponse } from "../src/ApiResponse";
import { validateBody, validateParams, validateQuery } from "../src/middleware/validate";
import {
    scanCreateBodySchema,
    scanIdParamsSchema,
    ScanCreateBody,
    ScanIdParams,
    scanListQuerySchema,
    ScanListQuery,
} from "../src/schemas/scans";
import logger from "../src/services/logger";
import {
    ProcessScanError,
    analyzeScanById,
    createScan,
    getScanById,
    getScanDetections,
    getScanProcessingStatus,
    listScans,
} from "../src/services/processScan";

const router = require("express").Router();

// GET /api/scans
// - Return existing scans for bootstrap and discovery.
router.get('/', validateQuery(scanListQuerySchema), async (req: Request, res: Response) => {
    const { roomName, limit, offset } = scanListQuerySchema.parse(req.query) as ScanListQuery;

    try {
        const result = await listScans({
            roomName,
            limit,
            offset,
        });

        return res.json(new ApiResponse(true, 'Scans fetched', result));
    } catch (err) {
        if (err instanceof ProcessScanError) {
            return res.status(err.statusCode).json(new ApiResponse(false, err.message));
        }

        logger.error('Unexpected error listing scans: %o', err);
        return res.status(500).json(new ApiResponse(false, 'Failed to list scans'));
    }
});

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
