import { analyzeImageWithVision } from "./gemini";
import logger from "./logger";
import supabase from "./supabase";
import {
  AIObjectDetection,
  DepthSample,
  Keyframe,
  Landmark,
  LandmarkType,
  ScanPoint,
  ScanUploadRequest,
  Vector3,
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

type PostgrestLikeError = {
  code?: string;
  message?: string;
};

type AnalyzeScanOptions = {
  keyframes?: Keyframe[];
  depthSamples?: DepthSample[];
  existingLandmarks?: Landmark[];
};

type ScanLandmarkRow = {
  type: string;
  label: string | null;
  confidence: number | null;
  source: string | null;
  x: number;
  y: number;
  z: number;
};

type ScanPointRow = {
  timestamp_ms: number | null;
  x: number;
  y: number;
  z: number;
};

type AIDetectionRow = {
  label: string;
  confidence: number;
  bbox_x: number | null;
  bbox_y: number | null;
  bbox_width: number | null;
  bbox_height: number | null;
};

const MAX_SCAN_KEYFRAMES_ANALYZED = Number.isFinite(Number(process.env.MAX_SCAN_KEYFRAMES_ANALYZED))
  ? Math.max(1, Math.trunc(Number(process.env.MAX_SCAN_KEYFRAMES_ANALYZED)))
  : 8;

const MIN_KEYFRAME_ANALYSIS_INTERVAL_MS = Number.isFinite(Number(process.env.MIN_KEYFRAME_ANALYSIS_INTERVAL_MS))
  ? Math.max(0, Math.trunc(Number(process.env.MIN_KEYFRAME_ANALYSIS_INTERVAL_MS)))
  : 1_500;

const ALLOWED_LANDMARK_TYPES: LandmarkType[] = [
  "door",
  "wall",
  "stair",
  "elevator",
  "obstacle",
  "exit",
  "unknown",
];

function asNumber(value: unknown, fallback = 0): number {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value;
  }
  if (typeof value === "string") {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) {
      return parsed;
    }
  }
  return fallback;
}

function clampConfidence(value: unknown): number | null {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return null;
  }
  if (value < 0) {
    return 0;
  }
  if (value > 1) {
    return 1;
  }
  return value;
}

function toLandmarkType(value: unknown): LandmarkType {
  if (typeof value !== "string") {
    return "unknown";
  }

  const normalized = value.toLowerCase();
  if (ALLOWED_LANDMARK_TYPES.includes(normalized as LandmarkType)) {
    return normalized as LandmarkType;
  }

  return "unknown";
}

function isUndefinedColumnError(error: PostgrestLikeError | null | undefined): boolean {
  if (!error) {
    return false;
  }

  return (
    error.code === "PGRST204" ||
    error.code === "42703" ||
    /could not find the '.+' column of '.+'/i.test(error.message ?? "") ||
    /column\s+.+\s+does not exist/i.test(error.message ?? "")
  );
}

function isUndefinedTableError(error: PostgrestLikeError | null | undefined): boolean {
  if (!error) {
    return false;
  }

  return (
    error.code === "42P01" ||
    /relation\s+.+\s+does not exist/i.test(error.message ?? "")
  );
}

function parseJsonArray<T>(value: unknown): T[] {
  if (Array.isArray(value)) {
    return value as T[];
  }

  if (typeof value === "string") {
    try {
      const parsed = JSON.parse(value);
      if (Array.isArray(parsed)) {
        return parsed as T[];
      }
    } catch {
      return [];
    }
  }

  return [];
}

function isAnalyzableKeyframe(keyframe: Keyframe): boolean {
  return Boolean(
    keyframe &&
    typeof keyframe.imageBase64 === "string" &&
    keyframe.imageBase64.trim().length > 0,
  );
}

function selectKeyframesForAnalysis(keyframes: Keyframe[]): Keyframe[] {
  const valid = keyframes.filter(isAnalyzableKeyframe);
  if (valid.length <= 1) {
    return valid;
  }

  const sorted = [...valid].sort(
    (a, b) => Number(a.timestamp ?? 0) - Number(b.timestamp ?? 0),
  );

  const spaced: Keyframe[] = [];
  let lastAcceptedTimestamp = Number.NEGATIVE_INFINITY;
  for (const keyframe of sorted) {
    const timestamp = Number(keyframe.timestamp ?? 0);
    if (
      spaced.length === 0 ||
      !Number.isFinite(timestamp) ||
      timestamp - lastAcceptedTimestamp >= MIN_KEYFRAME_ANALYSIS_INTERVAL_MS
    ) {
      spaced.push(keyframe);
      lastAcceptedTimestamp = timestamp;
    }
  }

  if (spaced.length <= MAX_SCAN_KEYFRAMES_ANALYZED) {
    return spaced;
  }

  const stride = Math.max(1, Math.ceil(spaced.length / MAX_SCAN_KEYFRAMES_ANALYZED));
  let sampled = spaced.filter((_, index) => index % stride === 0);

  const last = spaced[spaced.length - 1];
  if (sampled[sampled.length - 1] !== last) {
    sampled.push(last);
  }

  if (sampled.length > MAX_SCAN_KEYFRAMES_ANALYZED) {
    sampled = sampled.slice(0, MAX_SCAN_KEYFRAMES_ANALYZED);
    sampled[sampled.length - 1] = last;
  }

  return sampled;
}

function mapScanPointRowsToPoints(rows: ScanPointRow[]): ScanPoint[] {
  return rows.map((row) => ({
    x: asNumber(row.x),
    y: asNumber(row.y),
    z: asNumber(row.z),
    timestamp:
      typeof row.timestamp_ms === "number" && Number.isFinite(row.timestamp_ms)
        ? row.timestamp_ms
        : undefined,
  }));
}

function mapScanLandmarkRowsToLandmarks(rows: ScanLandmarkRow[]): Landmark[] {
  return rows.map((row) => ({
    type: toLandmarkType(row.type),
    label: row.label ?? undefined,
    confidence: clampConfidence(row.confidence) ?? undefined,
    source: row.source === "gemini" ? "gemini" : "user",
    x: asNumber(row.x),
    y: asNumber(row.y),
    z: asNumber(row.z),
  }));
}

function normalizeDetectedLandmark(
  landmark: Record<string, unknown>,
  fallbackPose: Vector3,
): Landmark {
  const pose =
    typeof landmark.cameraPose === "object" && landmark.cameraPose !== null
      ? (landmark.cameraPose as Record<string, unknown>)
      : null;

  return {
    type: toLandmarkType(landmark.type),
    label:
      typeof landmark.label === "string"
        ? landmark.label
        : typeof landmark.type === "string"
          ? landmark.type
          : "unknown",
    confidence: clampConfidence(landmark.confidence) ?? undefined,
    source: "gemini",
    x: asNumber(landmark.x, asNumber(pose?.x, fallbackPose.x)),
    y: asNumber(landmark.y, asNumber(pose?.y, fallbackPose.y)),
    z: asNumber(landmark.z, asNumber(pose?.z, fallbackPose.z)),
  };
}

function normalizeDetectedObstacle(
  obstacle: Record<string, unknown>,
): {
  label: string;
  confidence: number;
  boundingBox?: {
    x: number;
    y: number;
    width: number;
    height: number;
  };
} {
  const bbox =
    typeof obstacle.boundingBox === "object" && obstacle.boundingBox !== null
      ? (obstacle.boundingBox as Record<string, unknown>)
      : null;

  const normalized = {
    label:
      typeof obstacle.label === "string" && obstacle.label.trim().length > 0
        ? obstacle.label
        : "unknown",
    confidence: clampConfidence(obstacle.confidence) ?? 0,
  } as {
    label: string;
    confidence: number;
    boundingBox?: {
      x: number;
      y: number;
      width: number;
      height: number;
    };
  };

  if (bbox) {
    normalized.boundingBox = {
      x: asNumber(bbox.x),
      y: asNumber(bbox.y),
      width: asNumber(bbox.width),
      height: asNumber(bbox.height),
    };
  }

  return normalized;
}

async function readPersistedAIDetections(scanId: string): Promise<AIObjectDetection[]> {
  const { data, error } = await supabase
    .from("ai_detections")
    .select("label, confidence, bbox_x, bbox_y, bbox_width, bbox_height")
    .eq("scan_id", scanId)
    .order("id", { ascending: true });

  if (error) {
    if (isUndefinedTableError(error)) {
      logger.warn("ai_detections table is unavailable; falling back to landmark detections.");
      return [];
    }

    logger.error("Error fetching ai_detections rows: %o", error);
    throw new ProcessScanError(500, "Failed to fetch persisted detections");
  }

  return ((data ?? []) as AIDetectionRow[]).map((row) => {
    const detection: AIObjectDetection = {
      label: row.label,
      confidence: Number(clampConfidence(row.confidence) ?? 0),
    };

    if (
      typeof row.bbox_x === "number" &&
      typeof row.bbox_y === "number" &&
      typeof row.bbox_width === "number" &&
      typeof row.bbox_height === "number"
    ) {
      detection.boundingBox = {
        x: row.bbox_x,
        y: row.bbox_y,
        width: row.bbox_width,
        height: row.bbox_height,
      };
    }

    return detection;
  });
}

async function saveLegacyScanPayload(
  scanId: string,
  request: ScanUploadRequest,
): Promise<void> {
  const legacyUpdate = {
    points: JSON.stringify(request.points),
    landmarks: JSON.stringify(request.landmarks),
    started_at: request.startedAt,
    ended_at: request.endedAt,
    device_info: JSON.stringify(request.device),
    keyframes: JSON.stringify(request.keyframes),
    depth_samples: JSON.stringify(request.depthSamples),
  };

  const { error } = await supabase
    .from("scans")
    .update(legacyUpdate)
    .eq("id", scanId);

  if (!error) {
    return;
  }

  if (isUndefinedColumnError(error)) {
    logger.info(
      "Legacy scan payload columns are not present; continuing with normalized storage only.",
    );
    return;
  }

  logger.warn("Failed to persist legacy scan payload for %s: %o", scanId, error);
}

async function readNormalizedScanLandmarks(scanId: string): Promise<Landmark[]> {
  const { data, error } = await supabase
    .from("scan_landmarks")
    .select("type, label, confidence, source, x, y, z")
    .eq("scan_id", scanId);

  if (error) {
    if (isUndefinedTableError(error)) {
      logger.warn("scan_landmarks table is unavailable; falling back to legacy JSON.");
      return [];
    }

    logger.error("Error fetching normalized scan landmarks: %o", error);
    throw new ProcessScanError(500, "Failed to fetch scan landmarks");
  }

  return mapScanLandmarkRowsToLandmarks((data ?? []) as ScanLandmarkRow[]);
}

async function readNormalizedScanPoints(scanId: string): Promise<ScanPoint[]> {
  const { data, error } = await supabase
    .from("scan_points")
    .select("timestamp_ms, x, y, z")
    .eq("scan_id", scanId)
    .order("id", { ascending: true });

  if (error) {
    if (isUndefinedTableError(error)) {
      logger.warn("scan_points table is unavailable; falling back to legacy JSON.");
      return [];
    }

    logger.error("Error fetching normalized scan points: %o", error);
    throw new ProcessScanError(500, "Failed to fetch scan points");
  }

  return mapScanPointRowsToPoints((data ?? []) as ScanPointRow[]);
}

export async function createScan(request: ScanUploadRequest): Promise<string> {
  const { data: insertedScan, error } = await supabase
    .from("scans")
    .insert({
      room_name: request.roomName,
      processing_status: "uploaded",
      created_at: new Date().toISOString(),
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

  const pointRows = request.points.map((point) => ({
    scan_id: scanId,
    timestamp_ms:
      typeof point.timestamp === "number" && Number.isFinite(point.timestamp)
        ? Math.trunc(point.timestamp)
        : null,
    x: point.x,
    y: point.y,
    z: point.z,
  }));

  const { error: pointError } = await supabase.from("scan_points").insert(pointRows);
  if (pointError) {
    logger.error("Error inserting scan points: %o", pointError);
    throw new ProcessScanError(500, "Failed to save scan points");
  }

  const landmarkRows = request.landmarks.map((landmark) => ({
    scan_id: scanId,
    type: toLandmarkType(landmark.type),
    label: landmark.label ?? null,
    confidence: clampConfidence(landmark.confidence),
    source: landmark.source === "gemini" ? "gemini" : "user",
    x: landmark.x,
    y: landmark.y,
    z: landmark.z,
  }));

  const { error: landmarkError } = await supabase
    .from("scan_landmarks")
    .insert(landmarkRows);

  if (landmarkError) {
    logger.error("Error inserting scan landmarks: %o", landmarkError);
    throw new ProcessScanError(500, "Failed to save scan landmarks");
  }

  await saveLegacyScanPayload(scanId, request);

  return scanId;
}

export async function analyzeScanById(
  scanId: string,
  options?: AnalyzeScanOptions,
): Promise<AnalyzeScanResult> {
  const { data, error } = await supabase
    .from("scans")
    .select("*")
    .eq("id", scanId)
    .single();

  if (error) {
    logger.error("Error fetching scan keyframes from database: %o", error);
    throw new ProcessScanError(500, "Failed to fetch scan keyframes");
  }
  if (!data) {
    throw new ProcessScanError(404, "Scan not found");
  }

  const row = data as Record<string, unknown>;
  const keyframes = options?.keyframes ?? parseJsonArray<Keyframe>(row.keyframes);
  const depthSamples =
    options?.depthSamples ?? parseJsonArray<DepthSample>(row.depth_samples);

  let existingLandmarks = options?.existingLandmarks ?? [];
  if (existingLandmarks.length === 0) {
    existingLandmarks = await readNormalizedScanLandmarks(scanId);
  }
  if (existingLandmarks.length === 0) {
    existingLandmarks = parseJsonArray<Landmark>(row.landmarks);
  }

  const keyframesToAnalyze = selectKeyframesForAnalysis(keyframes);

  if (keyframesToAnalyze.length === 0) {
    throw new ProcessScanError(400, "No keyframes found for analysis");
  }

  if (keyframesToAnalyze.length < keyframes.length) {
    logger.info(
      "Scan %s keyframe analysis budget applied: %d received, %d analyzed (max=%d, minIntervalMs=%d)",
      scanId,
      keyframes.length,
      keyframesToAnalyze.length,
      MAX_SCAN_KEYFRAMES_ANALYZED,
      MIN_KEYFRAME_ANALYSIS_INTERVAL_MS,
    );
  }

  const { error: statusError } = await supabase
    .from("scans")
    .update({ processing_status: "ai-processing" })
    .eq("id", scanId);

  if (statusError) {
    logger.error("Error updating scan processing status: %o", statusError);
    throw new ProcessScanError(500, "Failed to update processing status");
  }

  const aiLandmarks: Landmark[] = [];
  const aiObstacles: Array<{
    label: string;
    confidence: number;
    boundingBox?: { x: number; y: number; width: number; height: number };
  }> = [];
  const aiDetectionRows: Array<{
    scan_id: string;
    label: string;
    confidence: number;
    bbox_x: number | null;
    bbox_y: number | null;
    bbox_width: number | null;
    bbox_height: number | null;
  }> = [];
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
    for (const keyframe of keyframesToAnalyze) {
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
      const analysis = await analyzeImageWithVision(imageData, depthData, cameraPose);

      const normalizedLandmarks = analysis.landmarks
        .filter(
          (landmark): landmark is Record<string, unknown> =>
            typeof landmark === "object" && landmark !== null,
        )
        .map((landmark) => normalizeDetectedLandmark(landmark, cameraPose));

      const normalizedObstacles = analysis.obstacles
        .filter(
          (obstacle): obstacle is Record<string, unknown> =>
            typeof obstacle === "object" && obstacle !== null,
        )
        .map((obstacle) => normalizeDetectedObstacle(obstacle));

      aiLandmarks.push(...normalizedLandmarks);
      aiObstacles.push(...normalizedObstacles);

      for (const landmark of normalizedLandmarks) {
        aiDetectionRows.push({
          scan_id: scanId,
          label: landmark.label ?? landmark.type,
          confidence: Number(clampConfidence(landmark.confidence) ?? 0),
          bbox_x: null,
          bbox_y: null,
          bbox_width: null,
          bbox_height: null,
        });
      }

      for (const obstacle of normalizedObstacles) {
        aiDetectionRows.push({
          scan_id: scanId,
          label: obstacle.label,
          confidence: Number(clampConfidence(obstacle.confidence) ?? 0),
          bbox_x: obstacle.boundingBox?.x ?? null,
          bbox_y: obstacle.boundingBox?.y ?? null,
          bbox_width: obstacle.boundingBox?.width ?? null,
          bbox_height: obstacle.boundingBox?.height ?? null,
        });
      }

      analyzedKeyframes.push({
        timestamp: Number(keyframe.timestamp ?? 0),
        landmarksDetected: normalizedLandmarks.length,
        obstaclesDetected: normalizedObstacles.length,
      });
    }

    if (aiLandmarks.length > 0) {
      const detectionRows = aiLandmarks.map((landmark) => ({
        scan_id: scanId,
        type: toLandmarkType(landmark.type),
        label: landmark.label ?? null,
        confidence: clampConfidence(landmark.confidence),
        source: "gemini",
        x: landmark.x,
        y: landmark.y,
        z: landmark.z,
      }));

      const { error: insertError } = await supabase
        .from("scan_landmarks")
        .insert(detectionRows);

      if (insertError && !isUndefinedTableError(insertError)) {
        logger.error("Error saving AI landmarks to scan_landmarks: %o", insertError);
        throw new ProcessScanError(
          500,
          "AI analysis completed but failed to save normalized landmarks",
        );
      }
    }

    if (aiDetectionRows.length > 0) {
      const { error: detectionsInsertError } = await supabase
        .from("ai_detections")
        .insert(aiDetectionRows);

      if (detectionsInsertError && !isUndefinedTableError(detectionsInsertError)) {
        logger.error("Error saving AI detections to ai_detections: %o", detectionsInsertError);
        throw new ProcessScanError(
          500,
          "AI analysis completed but failed to save detections",
        );
      }
    }

    const { error: statusCompleteError } = await supabase
      .from("scans")
      .update({ processing_status: "ai-processed" })
      .eq("id", scanId);

    if (statusCompleteError) {
      logger.error(
        "Error updating scan processing status to ai-processed: %o",
        statusCompleteError,
      );
      throw new ProcessScanError(500, "AI analysis completed but failed to finalize");
    }

    const mergedLandmarks = [...existingLandmarks, ...aiLandmarks];
    const { error: legacyUpdateError } = await supabase
      .from("scans")
      .update({ landmarks: JSON.stringify(mergedLandmarks) })
      .eq("id", scanId);

    if (legacyUpdateError && !isUndefinedColumnError(legacyUpdateError)) {
      logger.warn(
        "Unable to update legacy scans.landmarks field for %s: %o",
        scanId,
        legacyUpdateError,
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

  const row = data as Record<string, unknown>;

  const [normalizedPoints, normalizedLandmarks] = await Promise.all([
    readNormalizedScanPoints(scanId),
    readNormalizedScanLandmarks(scanId),
  ]);

  const fallbackPoints = parseJsonArray<ScanPoint>(row.points);
  const fallbackLandmarks = parseJsonArray<Landmark>(row.landmarks);

  return {
    ...row,
    points: normalizedPoints.length > 0 ? normalizedPoints : fallbackPoints,
    landmarks:
      normalizedLandmarks.length > 0 ? normalizedLandmarks : fallbackLandmarks,
  };
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
    .select("*")
    .eq("id", scanId)
    .single();

  if (error) {
    logger.error("Error fetching scan detections from database: %o", error);
    throw new ProcessScanError(500, "Failed to fetch detections");
  }

  if (!data) {
    throw new ProcessScanError(404, "Scan not found");
  }

  let detections = await readPersistedAIDetections(scanId);

  if (detections.length === 0) {
    const normalizedLandmarks = await readNormalizedScanLandmarks(scanId);
    detections = normalizedLandmarks
      .filter((landmark) => landmark.source === "gemini")
      .map((landmark) => ({
        label: landmark.label ?? landmark.type ?? "unknown",
        confidence: Number(clampConfidence(landmark.confidence) ?? 0),
      }));
  }

  if (detections.length === 0) {
    const legacyLandmarks = parseJsonArray<Landmark>(
      (data as Record<string, unknown>).landmarks,
    );

    detections = legacyLandmarks
      .filter((landmark) => landmark?.source === "gemini")
      .map((landmark) => ({
        label: landmark.label || landmark.type || "unknown",
        confidence: Number(clampConfidence(landmark.confidence) ?? 0),
      }));
  }

  return {
    id: scanId,
    processingStatus: (data as { processing_status?: string | null }).processing_status ?? null,
    detections,
    totalDetections: detections.length,
  };
}
