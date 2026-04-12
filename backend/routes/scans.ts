import { Request, Response } from "express";
import { createScan, getScanById } from "../src/services/processScan";

const router = require("express").Router();

router.post("/", async (req: Request, res: Response) => {
  try {
    const { userId, roomName, points, landmarks } = req.body;

    if (!userId || !roomName || !points) {
      res.status(400).json({ error: "Missing userId, roomName, or points" });
      return;
    }

    const result = await createScan({
      userId,
      roomName,
      points: points ?? [],
      landmarks: landmarks ?? [],
    });

    if (result.success) {
      res.status(201).json({ message: "Scan created", scanId: result.scanId, mapId: result.mapId });
    } else {
      res.status(500).json({ error: result.error });
    }
  } catch (err) {
    console.error("Scan creation error:", err);
    res.status(500).json({ error: "Internal server error" });
  }
});

router.get("/:id", async (req: Request, res: Response) => {
  try {
    const result = await getScanById(req.params.id as string);

    if (!result) {
      res.status(404).json({ error: "Scan not found" });
      return;
    }

    res.json(result);
  } catch (err) {
    console.error("Scan fetch error:", err);
    res.status(500).json({ error: "Internal server error" });
  }
});

module.exports = router;
