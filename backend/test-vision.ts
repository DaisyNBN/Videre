import "dotenv/config";
import { detectObjectsInImage } from "./src/services/geminiVision";
import fs from "fs";

const base64 = fs.readFileSync("photo_base64.txt", "utf-8");

detectObjectsInImage(base64)
  .then((d) => console.log("Detections:", JSON.stringify(d, null, 2)))
  .catch((e) => console.error("Error:", e.message));
