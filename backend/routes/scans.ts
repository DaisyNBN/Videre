import { Request, Response } from "express";
import { ScanUploadRequest } from "../src/types";
import { ApiResponse } from "../src/ApiResponse";
import logger from "../src/services/logger";
import {
    ProcessScanError,
    analyzeScanById,
    createScan,
    getScanById,
    getScanDetections,
    getScanProcessingStatus,
} from "../src/services/processScan";

const router = require("express").Router();

// POST /api/scans
// - Create a new scan upload record.
// - Accept`ScanUploadRequest` payload (`roomName`, scan timing/device data, points, landmarks, keyframes, depthSamples).
router.post('/', async (req: Request, res: Response) => {
    const { roomName, startedAt, endedAt, device, points, landmarks, keyframes, depthSamples } = req.body as ScanUploadRequest;
    // verify request data
    if (!roomName || !startedAt || !endedAt || !device || !points || !landmarks || !keyframes || !depthSamples) {
        return res.status(400).json(new ApiResponse(false, 'Missing required fields'));
    }
    if (!Array.isArray(points) || !Array.isArray(landmarks) || !Array.isArray(keyframes) || !Array.isArray(depthSamples)) {
        return res.status(400).json(new ApiResponse(false, 'Points, landmarks, keyframes, and depthSamples must be arrays'));
    }
    if (points.length === 0) {
        return res.status(400).json(new ApiResponse(false, 'Points array cannot be empty'));
    }
    if (landmarks.length === 0) {
        return res.status(400).json(new ApiResponse(false, 'Landmarks array cannot be empty'));
    }
    if (typeof roomName !== 'string') {
        return res.status(400).json(new ApiResponse(false, 'roomName must be a string'));
    }
    if (typeof startedAt !== 'string' || isNaN(Date.parse(startedAt))) {
        return res.status(400).json(new ApiResponse(false, 'startedAt must be a valid ISO date string'));
    }
    if (typeof endedAt !== 'string' || isNaN(Date.parse(endedAt))) {
        return res.status(400).json(new ApiResponse(false, 'endedAt must be a valid ISO date string'));
    }
    if (typeof device !== 'object' || !device.model || !device.osVersion || !device.appVersion) {
        return res.status(400).json(new ApiResponse(false, 'device must be an object with model, osVersion, and appVersion fields'));
    }

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
        await analyzeScanById(scanId);
    } catch (analysisError) {
        logger.error('Post-insert analysis failed for scan %s: %o', scanId, analysisError);
    }

    return res.status(201).json(new ApiResponse(true, 'Scan created', { id: scanId }));
});

// GET /api/scans/:scanId
// - Return scan details and metadata.
router.get('/:id', async (req: Request, res: Response) => {
    const scanId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
    // Validate scanId
    if (!scanId) {
        return res.status(400).json(new ApiResponse(false, 'Scan ID is required'));
    }

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
router.get('/:id/processing', async (req: Request, res: Response) => {
    const scanId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
    // Validate scanId
    if (!scanId) {
        return res.status(400).json(new ApiResponse(false, 'Scan ID is required'));
    }

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
router.post('/:id/analyze', async (req: Request, res: Response) => {
    const scanId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
    // Validate scanId
    if (!scanId) {
        return res.status(400).json(new ApiResponse(false, 'Scan ID is required'));
    }

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
router.get('/:id/detections', async (req: Request, res: Response) => {
    const scanId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
    if (!scanId) {
        return res.status(400).json(new ApiResponse(false, 'Scan ID is required'));
    }

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
