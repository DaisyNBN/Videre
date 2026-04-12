import { analyzeImageWithGemini } from "./gemini";
import logger from "./logger";
import supabase from "./supabase";
import {
  AIObjectDetection,
  DepthSample,
  Keyframe,
  Landmark,
  ScanUploadRequest,
} from "../types";

export type AnalyzeScanResult = {
  id: string;
  keyframesAnalyzed: number;
  aiLandmarksDetected: number;
  aiObstaclesDetected: number;
  keyframeSummary: Array<{
    timestamp: number;
    landmarksDetected: number;
    obstaclesDetected: number;
  }>;
  obstacles: any[];
};

export type ScanDetectionsResult = {
  id: string;
  processingStatus: string | null;
  detections: AIObjectDetection[];
  totalDetections: number;
};

export class ProcessScanError extends Error {
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

  if (typeof value === "string") {
    const parsed = JSON.parse(value);
    if (Array.isArray(parsed)) {
      return parsed as T[];
    }
  }

  return [];
}

export async function createScan(request: ScanUploadRequest): Promise<string> {
  const { data: insertedScan, error } = await supabase
    .from("scans")
    .insert({
      room_name: request.roomName,
      points: JSON.stringify(request.points),
      landmarks: JSON.stringify(request.landmarks),
      created_at: new Date().toISOString(),
      started_at: request.startedAt,
      ended_at: request.endedAt,
      device_info: JSON.stringify(request.device),
      keyframes: JSON.stringify(request.keyframes),
      depth_samples: JSON.stringify(request.depthSamples),
    })
    .select("id")
    .single();

  if (error) {
    logger.error("Error inserting scan into database: %o", error);
    throw new ProcessScanError(500, "Failed to create scan");
  }

  const scanId = insertedScan?.id;
  if (!scanId) {
    throw new ProcessScanError(500, "Scan created but ID was not returned");
  }

  return scanId;
}

export async function analyzeScanById(scanId: string): Promise<AnalyzeScanResult> {
  const { data, error } = await supabase
    .from("scans")
    .select("keyframes, depth_samples, landmarks")
    .eq("id", scanId)
    .single();

  if (error) {
    logger.error("Error fetching scan keyframes from database: %o", error);
    throw new ProcessScanError(500, "Failed to fetch scan keyframes");
  }
  if (!data) {
    throw new ProcessScanError(404, "Scan not found");
  }

  const keyframes = parseJsonArray<Keyframe>(data.keyframes);
  const depthSamples = parseJsonArray<DepthSample>(data.depth_samples);
  const existingLandmarks = parseJsonArray<Landmark>(data.landmarks);

  if (keyframes.length === 0) {
    throw new ProcessScanError(400, "No keyframes found for analysis");
  }

  const { error: statusError } = await supabase
    .from("scans")
    .update({ processing_status: "ai-processing" })
    .eq("id", scanId);

  if (statusError) {
    logger.error("Error updating scan processing status: %o", statusError);
    throw new ProcessScanError(500, "Failed to update processing status");
  }

  const aiLandmarks: any[] = [];
  const aiObstacles: any[] = [];
  const analyzedKeyframes: Array<{
    timestamp: number;
    landmarksDetected: number;
    obstaclesDetected: number;
  }> = [];

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
      if (
        !keyframe ||
        typeof keyframe.imageBase64 !== "string" ||
        !keyframe.imageBase64.trim()
      ) {
        logger.warn("Skipping invalid keyframe for scan %s", scanId);
        continue;
      }

      const imageData = keyframe.imageBase64.startsWith("data:image/")
        ? keyframe.imageBase64
        : `data:image/jpeg;base64,${keyframe.imageBase64}`;

      const depthData = nearestDepthSample(Number(keyframe.timestamp ?? 0));
      const cameraPose = keyframe.cameraPose ?? { x: 0, y: 0, z: 0 };

      logger.info(
        "Triggering AI analysis for keyframe at timestamp %d",
        keyframe.timestamp,
      );
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
      .from("scans")
      .update({
        landmarks: JSON.stringify(mergedLandmarks),
        processing_status: "ai-processed",
      })
      .eq("id", scanId);

    if (updateError) {
      logger.error("Error saving AI analysis results to database: %o", updateError);
      throw new ProcessScanError(
        500,
        "AI analysis completed but failed to save results",
      );
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
    logger.error("Error during scan analysis for %s: %o", scanId, err);
    await supabase
      .from("scans")
      .update({ processing_status: "failed" })
      .eq("id", scanId);

    if (err instanceof ProcessScanError) {
      throw err;
    }

    throw new ProcessScanError(500, "Failed to analyze scan keyframes");
  }
}

export async function getScanById(scanId: string): Promise<any> {
  const { data, error } = await supabase
    .from("scans")
    .select("*")
    .eq("id", scanId)
    .single();

  if (error) {
    logger.error("Error fetching scan from database: %o", error);
    throw new ProcessScanError(500, "Failed to fetch scan");
  }

  if (!data) {
    throw new ProcessScanError(404, "Scan not found");
  }

  return data;
}

export async function getScanProcessingStatus(
  scanId: string,
): Promise<{ processing_status: string | null }> {
  const { data, error } = await supabase
    .from("scans")
    .select("processing_status")
    .eq("id", scanId)
    .single();

  if (error) {
    logger.error("Error fetching scan processing status from database: %o", error);
    throw new ProcessScanError(500, "Failed to fetch processing status");
  }

  if (!data) {
    throw new ProcessScanError(404, "Scan not found");
  }

  return data;
}

export async function getScanDetections(scanId: string): Promise<ScanDetectionsResult> {
  const { data, error } = await supabase
    .from("scans")
    .select("landmarks, processing_status")
    .eq("id", scanId)
    .single();

  if (error) {
    logger.error("Error fetching scan detections from database: %o", error);
    throw new ProcessScanError(500, "Failed to fetch detections");
  }

  if (!data) {
    throw new ProcessScanError(404, "Scan not found");
  }

  const landmarks = parseJsonArray<Landmark>(data.landmarks);
  const detections: AIObjectDetection[] = landmarks
    .filter((landmark) => landmark?.source === "gemini")
    .map((landmark) => ({
      label: landmark.label || landmark.type || "unknown",
      confidence: Number(landmark.confidence ?? 0),
    }));

  return {
    id: scanId,
    processingStatus: data.processing_status ?? null,
    detections,
    totalDetections: detections.length,
  };
}
