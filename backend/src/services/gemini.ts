import { GoogleGenerativeAI } from "@google/generative-ai";
import { NavRequest, NavResponse, Obstacle } from "../types";
import { getFallbackResponse } from "../fallback";


const GEMINI_TIMEOUT_MS = 3000;

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

    const model = genAI.getGenerativeModel({ model: "gemini-1.5-flash" });

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
  try {
    if (!genAI) {
      throw new Error("Missing GEMINI_API_KEY");
    }

    let mimeType: string;
    let base64Image: string;

    if (imageUrl.startsWith("data:")) {
      const match = imageUrl.match(/^data:(image\/[a-zA-Z0-9.+-]+);base64,(.+)$/);
      if (!match) {
        throw new Error("Invalid base64 data URI format");
      }

      mimeType = match[1];
      base64Image = match[2];
    } else {
      const imageResponse = await fetch(imageUrl);
      if (!imageResponse.ok) {
        throw new Error(`Failed to fetch image: ${imageResponse.status} ${imageResponse.statusText}`);
      }

      mimeType = imageResponse.headers.get("content-type") || "image/jpeg";
      const imageBuffer = Buffer.from(await imageResponse.arrayBuffer());
      base64Image = imageBuffer.toString("base64");
    }

    const model = genAI.getGenerativeModel({ model: "gemini-1.5-flash" });

    const visionPrompt = `You are an indoor accessibility scene parser.

Analyze the provided image and return JSON only (no markdown, no backticks) in this exact shape:
{
  "landmarks": [
    {
      "type": "door|wall|stair|elevator|obstacle|exit|unknown",
      "label": "string",
      "confidence": 0.0,
      "source": "gemini"
    }
  ],
  "obstacles": [
    {
      "label": "string",
      "position": "left|center|right",
      "distance_estimate": "near|mid|far",
      "confidence": 0.0
    }
  ]
}

Context:
- cameraPose: ${JSON.stringify(cameraPose)}
- depthData: ${JSON.stringify(depthData ?? null)}

Rules:
- Return empty arrays when uncertain.
- Only use allowed enum values.
- Keep labels short and practical for blind navigation.
- Confidence must be a number between 0 and 1.`;

    const result = await Promise.race([
      model.generateContent([
        { text: visionPrompt },
        {
          inlineData: {
            mimeType,
            data: base64Image,
          },
        },
      ]),
      new Promise<never>((_, reject) =>
        setTimeout(() => reject(new Error("Gemini vision timeout")), GEMINI_TIMEOUT_MS)
      ),
    ]);

    const text = result.response.text();
    return parseVisionPayload(text);
  } catch (err) {
    console.error("Gemini vision analysis failed:", err);
    return { landmarks: [], obstacles: [] };
  }
}
