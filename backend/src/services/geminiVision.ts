import { GoogleGenerativeAI } from "@google/generative-ai";
import { AIObjectDetection } from "../types";

const genAI = new GoogleGenerativeAI(process.env.GEMINI_API_KEY ?? "");

export async function detectObjectsInImage(
  imageBase64: string,
  mimeType: string = "image/jpeg"
): Promise<AIObjectDetection[]> {
  const model = genAI.getGenerativeModel({ model: "gemini-2.5-flash-lite" });

  const result = await model.generateContent([
    {
      inlineData: {
        data: imageBase64,
        mimeType,
      },
    },
    `Identify all objects in this image that matter for a blind person navigating indoors.
Return ONLY valid JSON array, no markdown, no backticks:
[{"label":"door","confidence":0.95},{"label":"chair","confidence":0.8}]
Focus on: doors, stairs, walls, chairs, tables, obstacles, elevators, exits, people.
Max 10 objects. Confidence 0-1.`,
  ]);

  const text = result.response.text();
  const cleaned = text.replace(/```json\n?/g, "").replace(/```\n?/g, "").trim();
  return JSON.parse(cleaned) as AIObjectDetection[];
}
