import { GoogleGenerativeAI } from "@google/generative-ai";
import { ImageAnnotatorClient } from "@google-cloud/vision";
import { getFallbackResponse } from "../fallback";
import { NavRequest, NavResponse, Obstacle } from "../types";


const GEMINI_TIMEOUT_MS = 3000;
const visionClient = new ImageAnnotatorClient();

const geminiApiKey = process.env.GEMINI_API_KEY;
const genAI = geminiApiKey ? new GoogleGenerativeAI(geminiApiKey) : null;

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
    // Fix 2: Gemini failed or timed out — fallback keeps the user safe
    console.error("Gemini error, using fallback:", err);
    return getFallbackResponse(request.obstacles, checkpoint);
  }
}

export async function analyzeImageWithGemini(
  imageUrl: string,
  depthData: unknown,
  cameraPose: { x: number; y: number; z: number }
): Promise<{ landmarks: any[]; obstacles: any[] }> {
  // verify inputs
  if (!imageUrl) {
    throw new Error("Image URL is required");
  }
  if (!cameraPose || typeof cameraPose.x !== "number" || typeof cameraPose.y !== "number" || typeof cameraPose.z !== "number") {
    throw new Error("Valid camera pose is required");
  }

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

  try {
    const image = imageUrl.startsWith("data:")
      ? (() => {
        const match = imageUrl.match(/^data:image\/[a-zA-Z0-9.+-]+;base64,(.+)$/);
        if (!match) {
          throw new Error("Invalid base64 data URI format");
        }
        return { content: match[1] };
      })()
      : /^https?:\/\//i.test(imageUrl)
        ? (() => {
          return null;
        })()
        : { source: { filename: imageUrl } };

    let imageRequest = image;
    if (!imageRequest && /^https?:\/\//i.test(imageUrl)) {
      const imageResponse = await fetch(imageUrl);
      if (!imageResponse.ok) {
        throw new Error(`Failed to fetch image: ${imageResponse.status} ${imageResponse.statusText}`);
      }
      const imageBuffer = Buffer.from(await imageResponse.arrayBuffer());
      imageRequest = { content: imageBuffer.toString("base64") };
    }

    if (!imageRequest) {
      throw new Error("Unable to build image request for Vision API");
    }

    const [result] = await Promise.race([
      visionClient.annotateImage({
        image: imageRequest,
        features: [
          { type: "OBJECT_LOCALIZATION" },
          { type: "LANDMARK_DETECTION" },
        ],
      }),
      new Promise<never>((_, reject) =>
        setTimeout(() => reject(new Error("Gemini vision timeout")), GEMINI_TIMEOUT_MS)
      ),
    ]);

    const objects = result.localizedObjectAnnotations ?? [];
    const landmarksDetected = result.landmarkAnnotations ?? [];

    const obstacles = objects.map((obj) => {
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
        confidence: Number(obj.score ?? 0),
      };
    });

    const landmarks = landmarksDetected.map((landmark) => {
      const latLng = landmark.locations?.[0]?.latLng;

      return {
        type: mapLandmarkType(landmark.description ?? undefined),
        label: landmark.description ?? "unknown",
        confidence: Number(landmark.score ?? 0),
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

    return { landmarks, obstacles };
  } catch (err) {
    console.error("Gemini vision analysis failed:", err);
    return { landmarks: [], obstacles: [] };
  }
}
