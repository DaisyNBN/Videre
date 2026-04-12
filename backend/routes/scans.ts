import { Request, Response } from "express";
import { AIObjectDetection, DepthSample, Keyframe, Landmark, ScanUploadRequest } from "../src/types";
import { ApiResponse } from "../src/ApiResponse";
import supabase from "../src/services/supabase";
import logger from "../src/services/logger";
import { analyzeImageWithGemini } from "../src/services/gemini";

const router = require("express").Router();

type AnalyzeScanResult = {
    id: string;
    keyframesAnalyzed: number;
    aiLandmarksDetected: number;
    aiObstaclesDetected: number;
    keyframeSummary: Array<{ timestamp: number; landmarksDetected: number; obstaclesDetected: number }>;
    obstacles: any[];
};

class ScanRouteError extends Error {
    statusCode: number;

    constructor(statusCode: number, message: string) {
        super(message);
        this.statusCode = statusCode;
    }
}

function parseJsonArray<T>(value: unknown): T[] {
    if (Array.isArray(value)) {
        return value as T[];
    }
    if (typeof value === 'string') {
        const parsed = JSON.parse(value);
        if (Array.isArray(parsed)) {
            return parsed as T[];
        }
    }
    return [];
}

async function analyzeScanById(scanId: string): Promise<AnalyzeScanResult> {
    const { data, error } = await supabase
        .from('scans')
        .select('keyframes, depth_samples, landmarks')
        .eq('id', scanId)
        .single();

    if (error) {
        logger.error('Error fetching scan keyframes from database: %o', error);
        throw new ScanRouteError(500, 'Failed to fetch scan keyframes');
    }
    if (!data) {
        throw new ScanRouteError(404, 'Scan not found');
    }

    const keyframes = parseJsonArray<Keyframe>(data.keyframes);
    const depthSamples = parseJsonArray<DepthSample>(data.depth_samples);
    const existingLandmarks = parseJsonArray<Landmark>(data.landmarks);

    if (keyframes.length === 0) {
        throw new ScanRouteError(400, 'No keyframes found for analysis');
    }

    const { error: statusError } = await supabase
        .from('scans')
        .update({ processing_status: 'ai-processing' })
        .eq('id', scanId);

    if (statusError) {
        logger.error('Error updating scan processing status: %o', statusError);
        throw new ScanRouteError(500, 'Failed to update processing status');
    }

    const aiLandmarks: any[] = [];
    const aiObstacles: any[] = [];
    const analyzedKeyframes: Array<{ timestamp: number; landmarksDetected: number; obstaclesDetected: number }> = [];

    const nearestDepthSample = (timestamp: number): DepthSample | null => {
        if (depthSamples.length === 0) {
            return null;
        }

        let closest = depthSamples[0];
        let minDiff = Math.abs((closest.timestamp ?? 0) - timestamp);
        for (const sample of depthSamples) {
            const diff = Math.abs((sample.timestamp ?? 0) - timestamp);
            if (diff < minDiff) {
                minDiff = diff;
                closest = sample;
            }
        }
        return closest;
    };

    try {
        for (const keyframe of keyframes) {
            if (!keyframe || typeof keyframe.imageBase64 !== 'string' || !keyframe.imageBase64.trim()) {
                logger.warn('Skipping invalid keyframe for scan %s', scanId);
                continue;
            }

            const imageData = keyframe.imageBase64.startsWith('data:image/')
                ? keyframe.imageBase64
                : `data:image/jpeg;base64,${keyframe.imageBase64}`;

            const depthData = nearestDepthSample(Number(keyframe.timestamp ?? 0));
            const cameraPose = keyframe.cameraPose ?? { x: 0, y: 0, z: 0 };

            logger.info('Triggering AI analysis for keyframe at timestamp %d', keyframe.timestamp);
            const analysis = await analyzeImageWithGemini(imageData, depthData, cameraPose);

            aiLandmarks.push(...analysis.landmarks);
            aiObstacles.push(...analysis.obstacles);
            analyzedKeyframes.push({
                timestamp: Number(keyframe.timestamp ?? 0),
                landmarksDetected: analysis.landmarks.length,
                obstaclesDetected: analysis.obstacles.length,
            });
        }

        const mergedLandmarks = [...existingLandmarks, ...aiLandmarks];
        const { error: updateError } = await supabase
            .from('scans')
            .update({
                landmarks: JSON.stringify(mergedLandmarks),
                processing_status: 'ai-processed',
            })
            .eq('id', scanId);

        if (updateError) {
            logger.error('Error saving AI analysis results to database: %o', updateError);
            throw new ScanRouteError(500, 'AI analysis completed but failed to save results');
        }

        return {
            id: scanId,
            keyframesAnalyzed: analyzedKeyframes.length,
            aiLandmarksDetected: aiLandmarks.length,
            aiObstaclesDetected: aiObstacles.length,
            keyframeSummary: analyzedKeyframes,
            obstacles: aiObstacles,
        };
    } catch (err) {
        logger.error('Error during scan analysis for %s: %o', scanId, err);
        await supabase
            .from('scans')
            .update({ processing_status: 'failed' })
            .eq('id', scanId);

        if (err instanceof ScanRouteError) {
            throw err;
        }

        throw new ScanRouteError(500, 'Failed to analyze scan keyframes');
    }
}

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
    // Insert scan record into database
    const { data: insertedScan, error } = await supabase
        .from('scans')
        .insert({
            room_name: roomName,
            points: JSON.stringify(points),
            landmarks: JSON.stringify(landmarks),
            created_at: new Date().toISOString(),
            started_at: startedAt,
            ended_at: endedAt,
            device_info: JSON.stringify(device),
            keyframes: JSON.stringify(keyframes),
            depth_samples: JSON.stringify(depthSamples)
        })
        .select('id')
        .single();
    if (error) {
        logger.error('Error inserting scan into database: %o', error);
        return res.status(500).json(new ApiResponse(false, 'Failed to create scan'));
    }

    const scanId = insertedScan?.id;
    if (!scanId) {
        return res.status(500).json(new ApiResponse(false, 'Scan created but ID was not returned'));
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
    const scanId = req.params.id;
    // Validate scanId
    if (!scanId) {
        return res.status(400).json(new ApiResponse(false, 'Scan ID is required'));
    }
    const { data, error } = await supabase
        .from('scans')
        .select('*')
        .eq('id', scanId)
        .single();
    if (error) {
        logger.error('Error fetching scan from database: %o', error);
        return res.status(500).json(new ApiResponse(false, 'Failed to fetch scan'));
    }
    if (!data) {
        return res.status(404).json(new ApiResponse(false, 'Scan not found'));
    }
    // Handle fetching scan details
    res.json(new ApiResponse(true, 'Scan fetched', data));
});

// GET / api / scans /: scanId / processing
// - Return processing status (`uploaded`, `ai - processing`, `graph - built`, `failed`).
router.get('/:id/processing', async (req: Request, res: Response) => {
    const scanId = req.params.id;
    // Validate scanId
    if (!scanId) {
        return res.status(400).json(new ApiResponse(false, 'Scan ID is required'));
    }
    const { data, error } = await supabase
        .from('scans')
        .select('processing_status')
        .eq('id', scanId)
        .single();
    if (error) {
        logger.error('Error fetching scan processing status from database: %o', error);
        return res.status(500).json(new ApiResponse(false, 'Failed to fetch processing status'));
    }
    if (!data) {
        return res.status(404).json(new ApiResponse(false, 'Scan not found'));
    }
    // Handle fetching processing status
    res.json(new ApiResponse(true, 'Processing status fetched', data));
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
        if (err instanceof ScanRouteError) {
            return res.status(err.statusCode).json(new ApiResponse(false, err.message));
        }

        logger.error('Unexpected error during scan analysis for %s: %o', scanId, err);
        return res.status(500).json(new ApiResponse(false, 'Failed to analyze scan keyframes'));
    }
});

// GET /api/scans/:scanId/detections
// - Return AIObjectDetection[] with confidence and optional bounding box.
router.get('/:id/detections', async (req: Request, res: Response) => {
    const scanId = req.params.id;
    if (!scanId) {
        return res.status(400).json(new ApiResponse(false, 'Scan ID is required'));
    }

    try {
        const { data, error } = await supabase
            .from('scans')
            .select('landmarks, processing_status')
            .eq('id', scanId)
            .single();

        if (error) {
            logger.error('Error fetching scan detections from database: %o', error);
            return res.status(500).json(new ApiResponse(false, 'Failed to fetch detections'));
        }
        if (!data) {
            return res.status(404).json(new ApiResponse(false, 'Scan not found'));
        }

        const landmarks = parseJsonArray<Landmark>(data.landmarks);
        const detections: AIObjectDetection[] = landmarks
            .filter((landmark) => landmark?.source === 'gemini')
            .map((landmark) => ({
                label: landmark.label || landmark.type || 'unknown',
                confidence: Number(landmark.confidence ?? 0),
            }));

        return res.json(
            new ApiResponse(true, 'Detections fetched', {
                id: scanId,
                processingStatus: data.processing_status,
                detections,
                totalDetections: detections.length,
            }),
        );
    } catch (err) {
        logger.error('Error during detection fetch for %s: %o', scanId, err);
        return res.status(500).json(new ApiResponse(false, 'Failed to fetch detections'));
    }
});

export default router;
