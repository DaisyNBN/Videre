import { GoogleGenerativeAI } from "@google/generative-ai";
import { createHash } from "crypto";
import { AIObjectDetection, LandmarkType } from "../types";

type GeminiImageAnalysis = {
  landmarks: Array<{
    type: LandmarkType;
    label: string;
    confidence: number;
  }>;
  obstacles: Array<{
    label: string;
    confidence: number;
    position: "left" | "center" | "right";
    distance_estimate: "near" | "mid" | "far";
    boundingBox?: {
      x: number;
      y: number;
      width: number;
      height: number;
    };
  }>;
};

const geminiApiKey = process.env.GEMINI_API_KEY;
const genAI = geminiApiKey ? new GoogleGenerativeAI(geminiApiKey) : null;
const GEMINI_IMAGE_MODEL = process.env.GEMINI_IMAGE_MODEL ?? "gemini-2.5-flash-lite";
const GEMINI_IMAGE_CACHE_MAX = 200;
const GEMINI_IMAGE_MIN_COOLDOWN_MS = 60_000;

let geminiImageQuotaBlockedUntil = 0;
let geminiImageQuotaLastLoggedAt = 0;
const geminiImageCache = new Map<string, GeminiImageAnalysis>();

function getErrorStatus(error: unknown): number | null {
  if (!error || typeof error !== "object") {
    return null;
  }

  const maybeStatus = (error as { status?: unknown }).status;
  return typeof maybeStatus === "number" ? maybeStatus : null;
}

function getErrorMessage(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }

  if (typeof error === "string") {
    return error;
  }

  return "Unknown Gemini image error";
}

function isGeminiQuotaError(error: unknown): boolean {
  const status = getErrorStatus(error);
  if (status === 429) {
    return true;
  }

  const message = getErrorMessage(error);
  return /too many requests|quota exceeded|rate limit|429/i.test(message);
}

function parseRetryDelayMs(error: unknown): number | null {
  if (error && typeof error === "object") {
    const details = (error as { errorDetails?: unknown }).errorDetails;
    if (Array.isArray(details)) {
      for (const item of details) {
        if (!item || typeof item !== "object") {
          continue;
        }

        const retryDelay = (item as { retryDelay?: unknown }).retryDelay;
        if (typeof retryDelay === "string") {
          const secondsMatch = retryDelay.match(/([0-9]+(?:\.[0-9]+)?)s/i);
          if (secondsMatch) {
            return Math.ceil(Number(secondsMatch[1]) * 1000);
          }
        }
      }
    }
  }

  const message = getErrorMessage(error);
  const retryInMatch = message.match(/retry\s+in\s+([0-9]+(?:\.[0-9]+)?)s/i);
  if (retryInMatch) {
    return Math.ceil(Number(retryInMatch[1]) * 1000);
  }

  return null;
}

function cacheKey(imageBase64: string, mimeType: string): string {
  const hash = createHash("sha256").update(imageBase64).digest("hex");
  return `${mimeType}:${hash}`;
}

function readFromCache(key: string): GeminiImageAnalysis | null {
  const value = geminiImageCache.get(key);
  if (!value) {
    return null;
  }

  // Refresh insertion order for simple LRU behavior.
  geminiImageCache.delete(key);
  geminiImageCache.set(key, value);
  return value;
}

function writeToCache(key: string, value: GeminiImageAnalysis): void {
  if (geminiImageCache.has(key)) {
    geminiImageCache.delete(key);
  }

  geminiImageCache.set(key, value);

  while (geminiImageCache.size > GEMINI_IMAGE_CACHE_MAX) {
    const oldestKey = geminiImageCache.keys().next().value;
    if (!oldestKey) {
      break;
    }
    geminiImageCache.delete(oldestKey);
  }
}

function stripCodeFence(text: string): string {
  return text.replace(/```json\n?/g, "").replace(/```\n?/g, "").trim();
}

function clampConfidence(value: unknown): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return 0.5;
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
  if (typeof value === "string") {
    const normalized = value.toLowerCase();
    if (
      normalized === "door" ||
      normalized === "wall" ||
      normalized === "stair" ||
      normalized === "elevator" ||
      normalized === "obstacle" ||
      normalized === "exit" ||
      normalized === "unknown"
    ) {
      return normalized as LandmarkType;
    }
  }

  const label = typeof value === "string" ? value.toLowerCase() : "";
  if (label.includes("door")) return "door";
  if (label.includes("wall")) return "wall";
  if (label.includes("stair")) return "stair";
  if (label.includes("elevator") || label.includes("lift")) return "elevator";
  if (label.includes("exit")) return "exit";
  if (label.includes("obstacle") || label.includes("barrier")) return "obstacle";

  return "unknown";
}

function toPosition(value: unknown): "left" | "center" | "right" {
  if (value === "left" || value === "center" || value === "right") {
    return value;
  }
  return "center";
}

function toDistanceEstimate(value: unknown): "near" | "mid" | "far" {
  if (value === "near" || value === "mid" || value === "far") {
    return value;
  }
  return "mid";
}

function asNumber(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value;
  }
  if (typeof value === "string") {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) {
      return parsed;
    }
  }
  return null;
}

function normalizeBoundingBox(
  value: unknown,
): { x: number; y: number; width: number; height: number } | undefined {
  if (!value || typeof value !== "object") {
    return undefined;
  }

  const raw = value as Record<string, unknown>;
  const x = asNumber(raw.x);
  const y = asNumber(raw.y);
  const width = asNumber(raw.width);
  const height = asNumber(raw.height);

  if (
    x === null ||
    y === null ||
    width === null ||
    height === null ||
    width <= 0 ||
    height <= 0
  ) {
    return undefined;
  }

  return {
    x: Math.max(0, Math.min(1, x)),
    y: Math.max(0, Math.min(1, y)),
    width: Math.max(0, Math.min(1, width)),
    height: Math.max(0, Math.min(1, height)),
  };
}

function dedupeByKey<T>(items: T[], keySelector: (item: T) => string): T[] {
  const seen = new Set<string>();
  const out: T[] = [];

  for (const item of items) {
    const key = keySelector(item);
    if (seen.has(key)) {
      continue;
    }
    seen.add(key);
    out.push(item);
  }

  return out;
}

function normalizeGeminiImageAnalysis(raw: unknown): GeminiImageAnalysis {
  const asObject =
    raw && typeof raw === "object" && !Array.isArray(raw)
      ? (raw as Record<string, unknown>)
      : {};

  const rawLandmarks = Array.isArray(asObject.landmarks)
    ? asObject.landmarks
    : [];

  const rawObstacles = Array.isArray(asObject.obstacles)
    ? asObject.obstacles
    : Array.isArray(raw)
      ? raw
      : [];

  const landmarks = dedupeByKey(
    rawLandmarks
      .filter((item): item is Record<string, unknown> => !!item && typeof item === "object")
      .map((item) => {
        const label =
          typeof item.label === "string" && item.label.trim().length > 0
            ? item.label.trim()
            : "unknown";
        const type = toLandmarkType(item.type ?? label);
        return {
          type,
          label,
          confidence: clampConfidence(item.confidence),
        };
      }),
    (item) => `${item.type}:${item.label.toLowerCase()}`,
  );

  const obstacles = dedupeByKey(
    rawObstacles
      .filter((item): item is Record<string, unknown> => !!item && typeof item === "object")
      .map((item) => ({
        label:
          typeof item.label === "string" && item.label.trim().length > 0
            ? item.label.trim()
            : "unknown object",
        confidence: clampConfidence(item.confidence),
        position: toPosition(item.position),
        distance_estimate: toDistanceEstimate(item.distance_estimate),
        boundingBox: normalizeBoundingBox(item.boundingBox),
      })),
    (item) => `${item.label.toLowerCase()}:${item.position}:${item.distance_estimate}`,
  );

  return {
    landmarks,
    obstacles,
  };
}

export async function analyzeImageWithGeminiVision(
  imageBase64: string,
  mimeType: string = "image/jpeg",
): Promise<GeminiImageAnalysis> {
  if (!genAI || !imageBase64.trim()) {
    return { landmarks: [], obstacles: [] };
  }

  if (Date.now() < geminiImageQuotaBlockedUntil) {
    return { landmarks: [], obstacles: [] };
  }

  const key = cacheKey(imageBase64, mimeType);
  const cached = readFromCache(key);
  if (cached) {
    return cached;
  }

  const model = genAI.getGenerativeModel({ model: GEMINI_IMAGE_MODEL });

  try {
    const result = await model.generateContent([
      {
        inlineData: {
          data: imageBase64,
          mimeType,
        },
      },
      `You are analyzing a single indoor frame for blind-navigation assistance.
Return ONLY valid JSON (no markdown, no backticks) with this exact shape:
{
  "landmarks": [
    {"type":"door|wall|stair|elevator|obstacle|exit|unknown","label":"...","confidence":0.0}
  ],
  "obstacles": [
    {
      "label":"...",
      "confidence":0.0,
      "position":"left|center|right",
      "distance_estimate":"near|mid|far",
      "boundingBox":{"x":0.0,"y":0.0,"width":0.0,"height":0.0}
    }
  ]
}
Rules:
- Keep confidence in [0,1].
- Use normalized bounding box coordinates in [0,1] when possible.
- Include up to 12 total obstacles.
- Prioritize doors, stairs, elevators, exits, walls, people, chairs, tables, barriers, clutter.
- If uncertain, still return best-effort entries with lower confidence.
- Never output non-JSON text.`,
    ]);

    const text = result.response.text();
    const cleaned = stripCodeFence(text);
    const parsed = JSON.parse(cleaned);
    const normalized = normalizeGeminiImageAnalysis(parsed);
    writeToCache(key, normalized);
    return normalized;
  } catch (error) {
    if (isGeminiQuotaError(error)) {
      const retryDelay = parseRetryDelayMs(error) ?? GEMINI_IMAGE_MIN_COOLDOWN_MS;
      geminiImageQuotaBlockedUntil = Date.now() + Math.max(retryDelay, GEMINI_IMAGE_MIN_COOLDOWN_MS);

      if (Date.now() - geminiImageQuotaLastLoggedAt > 5_000) {
        geminiImageQuotaLastLoggedAt = Date.now();
        console.warn(
          `Gemini image fallback temporarily paused due to quota limits. Cooldown: ${Math.ceil((geminiImageQuotaBlockedUntil - Date.now()) / 1000)}s`,
        );
      }

      return { landmarks: [], obstacles: [] };
    }

    throw error;
  }
}

export async function detectObjectsInImage(
  imageBase64: string,
  mimeType: string = "image/jpeg"
): Promise<AIObjectDetection[]> {
  const analysis = await analyzeImageWithGeminiVision(imageBase64, mimeType);
  return analysis.obstacles.map((obstacle) => ({
    label: obstacle.label,
    confidence: obstacle.confidence,
    boundingBox: obstacle.boundingBox,
  }));
}
