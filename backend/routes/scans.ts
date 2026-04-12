import { Request, Response } from "express";
import { ScanUploadRequest } from "../src/types";
import { ApiResponse } from "../src/ApiResponse";
import supabase from "../src/services/supabase";
import logger from "../src/services/logger";

const router = require('express').Router();

// POST /api/scans
// - Create a new scan upload record.
// - Accept`ScanUploadRequest` payload(`userId`, `roomName`, `points`, `landmarks`).
router.post('/', async (req: Request, res: Response) => {
    const { userId, roomName, points, landmarks } = req.body as ScanUploadRequest;
    // verify request data
    if (!userId || !roomName || !points || !landmarks) {
        return res.status(400).json(new ApiResponse(false, 'Missing required fields'));
    }
    if (!Array.isArray(points) || !Array.isArray(landmarks)) {
        return res.status(400).json(new ApiResponse(false, 'Points and landmarks must be arrays'));
    }
    if (points.length === 0) {
        return res.status(400).json(new ApiResponse(false, 'Points array cannot be empty'));
    }
    if (landmarks.length === 0) {
        return res.status(400).json(new ApiResponse(false, 'Landmarks array cannot be empty'));
    }
    if (typeof userId !== 'string' || typeof roomName !== 'string') {
        return res.status(400).json(new ApiResponse(false, 'userId and roomName must be strings'));
    }
    // Insert scan record into database
    const { data, error } = await supabase
        .from('scans')
        .insert({
            user_id: userId,
            room_name: roomName,
            points: JSON.stringify(points),
            landmarks: JSON.stringify(landmarks),
            created_at: new Date().toISOString(),
        });
    if (error) {
        logger.error('Error inserting scan into database: %o', error);
        return res.status(500).json(new ApiResponse(false, 'Failed to create scan'));
    }
    // Handle scan creation
    res.status(201).json(new ApiResponse(true, 'Scan created', data));
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
    const scanId = req.params.id;
    // Validate scanId
    if (!scanId) {
        return res.status(400).json(new ApiResponse(false, 'Scan ID is required'));
    }
    // Trigger AI analysis (implementation pending)

    res.json(new ApiResponse(true, 'AI analysis triggered', { id: scanId }));
});

export default router;