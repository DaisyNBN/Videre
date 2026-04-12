import { GoogleGenerativeAI } from "@google/generative-ai";
import { NavRequest, NavResponse, Obstacle } from "../types";
import { getFallbackResponse } from "../fallback";
require("dotenv").config();

const GEMINI_TIMEOUT_MS = 3000;

const genAI = new GoogleGenerativeAI(process.env.GEMINI_API_KEY ?? "");

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

export async function getGeminiNavResponse(
  request: NavRequest,
  checkpoint?: { label: string; distance: number }
): Promise<NavResponse> {
  try {
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
