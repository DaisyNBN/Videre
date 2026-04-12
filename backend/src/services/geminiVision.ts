import { GoogleGenerativeAI } from "@google/generative-ai";
import { AIObjectDetection } from "../types";

const genAI = new GoogleGenerativeAI(process.env.GEMINI_API_KEY ?? "");

export async function detectObjectsInImage(
  imageBase64: string,
  mimeType: string = "image/jpeg"
): Promise<AIObjectDetection[]> {
  const startTime = Date.now();
  const model = genAI.getGenerativeModel({ model: "gemini-2.5-flash-lite" });

  const result = await model.generateContent([
    {
      inlineData: {
        data: imageBase64,
        mimeType,
      },
    },
    `Look at this indoor photo. List every physical object you can see.
For each object, give a short label and confidence score.
Return ONLY a JSON array like: [{"label":"stair","confidence":0.9}]

What objects do you see?`,
  ]);

  const text = result.response.text();
  const cleaned = text.replace(/```json\n?/g, "").replace(/```\n?/g, "").trim();
  const endTime = Date.now();
  console.log(`Gemini Vision took ${endTime - startTime}ms`);
  return JSON.parse(cleaned) as AIObjectDetection[];
}
