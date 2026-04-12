import { ImageAnnotatorClient } from "@google-cloud/vision";
import { GoogleGenerativeAI } from "@google/generative-ai";
import { existsSync } from "fs";
import { readFile } from "fs/promises";
import { homedir } from "os";
import { join } from "path";
import { getFallbackResponse } from "../fallback";
import { NavRequest, NavResponse, Obstacle } from "../types";
import { analyzeImageWithGeminiVision } from "./geminiVision";


const GEMINI_TIMEOUT_MS = 3000;
const IMAGE_ANALYSIS_TIMEOUT_MS = 5000;
const SPARSE_IMAGE_DETECTION_THRESHOLD = 2;
const GEMINI_NAV_MIN_COOLDOWN_MS = 60_000;
let visionClient: ImageAnnotatorClient | null = null;
let visionUnavailableReason: string | null = null;
let geminiNavBlockedUntil = 0;
let geminiNavLastLoggedAt = 0;

const geminiApiKey = process.env.GEMINI_API_KEY;
const genAI = geminiApiKey ? new GoogleGenerativeAI(geminiApiKey) : null;

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

  return "Unknown Gemini error";
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

function hasVisionCredentialHint(): boolean {
  const explicitPath = process.env.GOOGLE_APPLICATION_CREDENTIALS;
  if (explicitPath && explicitPath.trim().length > 0) {
    return existsSync(explicitPath);
  }

  const defaultAdcPath = join(
    homedir(),
    ".config",
    "gcloud",
    "application_default_credentials.json",
  );

  if (existsSync(defaultAdcPath)) {
    return true;
  }

  // Managed runtimes typically expose one of these env markers.
  return Boolean(
    process.env.K_SERVICE ||
    process.env.GAE_ENV ||
    process.env.FUNCTION_TARGET ||
    process.env.GCE_METADATA_HOST ||
    process.env.GOOGLE_CLOUD_PROJECT ||
    process.env.GCLOUD_PROJECT ||
    process.env.GCP_PROJECT,
  );
}

function getVisionClient(): ImageAnnotatorClient | null {
  if (visionUnavailableReason) {
    return null;
  }

  if (visionClient) {
    return visionClient;
  }

  if (!hasVisionCredentialHint()) {
    visionUnavailableReason =
      "Vision API disabled: no credential hints found (GOOGLE_APPLICATION_CREDENTIALS, local ADC, or managed runtime identity).";
    console.warn(visionUnavailableReason);
    return null;
  }

  visionClient = new ImageAnnotatorClient();
  return visionClient;
}

function buildPrompt(
  obstacles: Obstacle[],
  heading: number,
  speed: string,
  checkpoint?: { label: string; distance: number }
): string {
  const obstacleDesc =
    obstacles.length === 0
      ? "No obstacles detected."
      : obstacles
        .map(
          (o) =>
            `- ${o.label}: ${o.distance_estimate} distance, on the ${o.position}`
        )
        .join("\n");

  const checkpointDesc = checkpoint
    ? `Next checkpoint: ${checkpoint.label}, approximately ${checkpoint.distance} meters ahead.`
    : "No upcoming checkpoint.";

  return `You are a navigation assistant for a blind pedestrian using a smart cane.

Current situation:
- User is ${speed}
- Facing heading ${heading}°
- ${checkpointDesc}

Detected obstacles:
${obstacleDesc}

Respond with a JSON object (no markdown, no backticks) with these exact fields:
{
  "instruction": "<short spoken instruction, max 15 words, direct and clear>",
  "urgency": "<low | medium | high>",
  "haptic_pattern": "<none | single_tap | double_tap | continuous>"
}

Rules:
- If an obstacle is near and center, urgency must be "high" and haptic must be "continuous"
- If an obstacle is near but to one side, urgency is "medium" and haptic is "double_tap"
- Keep instructions concise — the user hears them while walking
- Use plain language: "step right", "keep left", "stop", "continue straight"
- Never say "I" or refer to yourself`;
}

function parseGeminiResponse(
  text: string,
  checkpoint?: { label: string; distance: number }
): NavResponse {
  const cleaned = text.replace(/```json\n?/g, "").replace(/```\n?/g, "").trim();
  const parsed = JSON.parse(cleaned);

  const validUrgency = ["low", "medium", "high"];
  const validHaptic = ["none", "single_tap", "double_tap", "continuous"];

  return {
    instruction: String(parsed.instruction ?? "Continue straight."),
    urgency: validUrgency.includes(parsed.urgency) ? parsed.urgency : "low",
    haptic_pattern: validHaptic.includes(parsed.haptic_pattern)
      ? parsed.haptic_pattern
      : "single_tap",
    next_checkpoint: checkpoint?.label ?? null,
    distance_to_next_m: checkpoint?.distance ?? null,
    fallback_used: false,
  };
}

function stripCodeFence(text: string): string {
  return text.replace(/```json\n?/g, "").replace(/```\n?/g, "").trim();
}

function parseVisionPayload(text: string): { landmarks: any[]; obstacles: any[] } {
  const parsed = JSON.parse(stripCodeFence(text));

  const landmarks = Array.isArray(parsed.landmarks) ? parsed.landmarks : [];
  const obstacles = Array.isArray(parsed.obstacles) ? parsed.obstacles : [];

  return { landmarks, obstacles };
}

export async function getGeminiNavResponse(
  request: NavRequest,
  checkpoint?: { label: string; distance: number }
): Promise<NavResponse> {
  if (Date.now() < geminiNavBlockedUntil) {
    return getFallbackResponse(request.obstacles, checkpoint);
  }

  try {
    if (!genAI) {
      throw new Error("Missing GEMINI_API_KEY");
    }

    const model = genAI.getGenerativeModel({ model: "gemini-2.5-flash-lite" });

    const prompt = buildPrompt(
      request.obstacles,
      request.heading_degrees,
      request.speed,
      checkpoint
    );

    // Fix 3: Timeout — a blind user can't wait 5+ seconds
    const result = await Promise.race([
      model.generateContent(prompt),
      new Promise<never>((_, reject) =>
        setTimeout(() => reject(new Error("Gemini timeout")), GEMINI_TIMEOUT_MS)
      ),
    ]);

    const text = result.response.text();
    const response = parseGeminiResponse(text, checkpoint);

    // Fix 1: Safety override — never let AI downgrade a critical urgency
    const blocking = request.obstacles.find(
      (o) => o.distance_estimate === "near" && o.position === "center"
    );
    if (blocking && response.urgency !== "high") {
      response.urgency = "high";
      response.haptic_pattern = "continuous";
    }

    return response;
  } catch (err) {
    if (isGeminiQuotaError(err)) {
      const retryDelay = parseRetryDelayMs(err) ?? GEMINI_NAV_MIN_COOLDOWN_MS;
      geminiNavBlockedUntil = Date.now() + Math.max(retryDelay, GEMINI_NAV_MIN_COOLDOWN_MS);

      if (Date.now() - geminiNavLastLoggedAt > 5_000) {
        geminiNavLastLoggedAt = Date.now();
        console.warn(
          `Gemini navigation temporarily paused due to quota limits. Cooldown: ${Math.ceil((geminiNavBlockedUntil - Date.now()) / 1000)}s`,
        );
      }
    } else {
      console.warn(`Gemini navigation fallback triggered: ${getErrorMessage(err)}`);
    }

    return getFallbackResponse(request.obstacles, checkpoint);
  }
}

export async function analyzeImageWithVision(
  imageUrl: string,
  depthData: unknown,
  cameraPose: { x: number; y: number; z: number }
): Promise<{ landmarks: any[]; obstacles: any[] }> {
  if (!imageUrl) {
    throw new Error("Image URL is required");
  }

  if (
    !cameraPose ||
    typeof cameraPose.x !== "number" ||
    typeof cameraPose.y !== "number" ||
    typeof cameraPose.z !== "number"
  ) {
    throw new Error("Valid camera pose is required");
  }

  const client = getVisionClient();

  const toPosition = (xCenter: number): "left" | "center" | "right" => {
    if (xCenter < 0.33) {
      return "left";
    }
    if (xCenter > 0.66) {
      return "right";
    }
    return "center";
  };

  const toDistanceEstimate = (area: number): "near" | "mid" | "far" => {
    if (area >= 0.2) {
      return "near";
    }
    if (area >= 0.07) {
      return "mid";
    }
    return "far";
  };

  const mapLandmarkType = (description?: string) => {
    const label = (description ?? "").toLowerCase();
    if (label.includes("door")) return "door";
    if (label.includes("wall")) return "wall";
    if (label.includes("stair") || label.includes("stairs")) return "stair";
    if (label.includes("elevator") || label.includes("lift")) return "elevator";
    if (label.includes("exit")) return "exit";
    if (label.includes("obstacle") || label.includes("barrier")) return "obstacle";
    return "unknown";
  };

  const clampConfidence = (value: unknown): number => {
    if (typeof value !== "number" || !Number.isFinite(value)) {
      return 0.5;
    }
    if (value < 0) return 0;
    if (value > 1) return 1;
    return value;
  };

  const mergeByConfidence = <T extends { confidence?: number }>(
    items: T[],
    keySelector: (item: T) => string,
  ): T[] => {
    const byKey = new Map<string, T>();
    for (const item of items) {
      const key = keySelector(item);
      const current = byKey.get(key);
      if (!current) {
        byKey.set(key, item);
        continue;
      }

      const currentConfidence =
        typeof current.confidence === "number" ? current.confidence : 0;
      const nextConfidence =
        typeof item.confidence === "number" ? item.confidence : 0;
      if (nextConfidence > currentConfidence) {
        byKey.set(key, item);
      }
    }

    return Array.from(byKey.values());
  };

  let mimeType = "image/jpeg";
  let imageBase64: string;

  try {
    if (imageUrl.startsWith("data:")) {
      const match = imageUrl.match(/^data:(image\/[a-zA-Z0-9.+-]+);base64,(.+)$/);
      if (!match) {
        throw new Error("Invalid base64 data URI format");
      }

      mimeType = match[1];
      imageBase64 = match[2];
    } else if (/^https?:\/\//i.test(imageUrl)) {
      const imageResponse = await fetch(imageUrl);
      if (!imageResponse.ok) {
        throw new Error(
          `Failed to fetch image: ${imageResponse.status} ${imageResponse.statusText}`,
        );
      }

      const responseMime = imageResponse.headers.get("content-type");
      if (responseMime && responseMime.startsWith("image/")) {
        mimeType = responseMime.split(";")[0] ?? mimeType;
      }

      const imageBuffer = Buffer.from(await imageResponse.arrayBuffer());
      imageBase64 = imageBuffer.toString("base64");
    } else {
      const imageBuffer = await readFile(imageUrl);
      imageBase64 = imageBuffer.toString("base64");
    }
  } catch (err) {
    console.error("Image loading failed for analysis:", err);
    return { landmarks: [], obstacles: [] };
  }

  const imageRequest = { content: imageBase64 };

  let visionLandmarks: any[] = [];
  let visionObstacles: any[] = [];
  let visionAttemptFailed = false;

  if (client) {
    try {
      const [result] = await Promise.race([
        client.annotateImage({
          image: imageRequest,
          features: [
            { type: "OBJECT_LOCALIZATION" },
            { type: "LANDMARK_DETECTION" },
          ],
        }),
        new Promise<never>((_, reject) =>
          setTimeout(() => reject(new Error("Vision API timeout")), IMAGE_ANALYSIS_TIMEOUT_MS),
        ),
      ]);

      const objects = result.localizedObjectAnnotations ?? [];
      const landmarksDetected = result.landmarkAnnotations ?? [];

      visionObstacles = objects.map((obj) => {
        const vertices = obj.boundingPoly?.normalizedVertices ?? [];
        const xs = vertices.map((v) => Number(v.x ?? 0));
        const ys = vertices.map((v) => Number(v.y ?? 0));

        const minX = xs.length ? Math.min(...xs) : 0;
        const maxX = xs.length ? Math.max(...xs) : 0;
        const minY = ys.length ? Math.min(...ys) : 0;
        const maxY = ys.length ? Math.max(...ys) : 0;
        const area = Math.max(0, maxX - minX) * Math.max(0, maxY - minY);
        const centerX = (minX + maxX) / 2;

        return {
          label: obj.name ?? "unknown object",
          position: toPosition(centerX),
          distance_estimate: toDistanceEstimate(area),
          confidence: clampConfidence(Number(obj.score ?? 0)),
          boundingBox: {
            x: minX,
            y: minY,
            width: Math.max(0, maxX - minX),
            height: Math.max(0, maxY - minY),
          },
        };
      });

      visionLandmarks = landmarksDetected.map((landmark) => {
        const latLng = landmark.locations?.[0]?.latLng;

        return {
          type: mapLandmarkType(landmark.description ?? undefined),
          label: landmark.description ?? "unknown",
          confidence: clampConfidence(Number(landmark.score ?? 0)),
          source: "gemini",
          location: latLng
            ? {
              latitude: Number(latLng.latitude ?? 0),
              longitude: Number(latLng.longitude ?? 0),
            }
            : null,
          cameraPose,
          depthData: depthData ?? null,
        };
      });
    } catch (err) {
      visionAttemptFailed = true;
      const errorMessage =
        err instanceof Error ? err.message : "Unknown Vision API error";

      if (/default credentials|metadata server|metadata lookup|auth/i.test(errorMessage)) {
        visionUnavailableReason = `Vision API disabled after auth failure: ${errorMessage}`;
        console.warn(visionUnavailableReason);
      } else {
        console.error("Vision API analysis failed:", err);
      }
    }
  }

  const visionSignalCount = visionLandmarks.length + visionObstacles.length;
  const shouldRunGeminiFallback = Boolean(genAI) && (
    !client ||
    visionAttemptFailed ||
    visionSignalCount < SPARSE_IMAGE_DETECTION_THRESHOLD
  );

  if (!shouldRunGeminiFallback) {
    return { landmarks: visionLandmarks, obstacles: visionObstacles };
  }

  try {
    const geminiFallback = await Promise.race([
      analyzeImageWithGeminiVision(imageBase64, mimeType),
      new Promise<never>((_, reject) =>
        setTimeout(
          () => reject(new Error("Gemini image analysis timeout")),
          IMAGE_ANALYSIS_TIMEOUT_MS,
        ),
      ),
    ]);

    const geminiLandmarks = geminiFallback.landmarks.map((landmark) => ({
      type: mapLandmarkType(landmark.type ?? landmark.label),
      label: landmark.label,
      confidence: clampConfidence(landmark.confidence),
      source: "gemini",
      cameraPose,
      depthData: depthData ?? null,
    }));

    const geminiObstacles = geminiFallback.obstacles.map((obstacle) => ({
      label: obstacle.label,
      confidence: clampConfidence(obstacle.confidence),
      position: obstacle.position,
      distance_estimate: obstacle.distance_estimate,
      boundingBox: obstacle.boundingBox,
    }));

    if (visionSignalCount === 0) {
      return {
        landmarks: geminiLandmarks,
        obstacles: geminiObstacles,
      };
    }

    return {
      landmarks: mergeByConfidence(
        [...visionLandmarks, ...geminiLandmarks],
        (landmark) => `${String(landmark.type)}:${String(landmark.label).toLowerCase()}`,
      ),
      obstacles: mergeByConfidence(
        [...visionObstacles, ...geminiObstacles],
        (obstacle) => {
          const box = obstacle.boundingBox
            ? `${obstacle.boundingBox.x}:${obstacle.boundingBox.y}:${obstacle.boundingBox.width}:${obstacle.boundingBox.height}`
            : "none";
          return `${String(obstacle.label).toLowerCase()}:${box}`;
        },
      ),
    };
  } catch (err) {
    if (isGeminiQuotaError(err)) {
      console.warn("Gemini image fallback skipped due to quota exhaustion.");
    } else {
      console.warn(`Gemini image fallback failed: ${getErrorMessage(err)}`);
    }

    return {
      landmarks: visionLandmarks,
      obstacles: visionObstacles,
    };
  }
}

// Backward-compatible alias while routes/services migrate naming.
export const analyzeImageWithGemini = analyzeImageWithVision;
