import { Request, Response, Router } from "express";
import { getNavigationInstruction } from "../src/services/processNavigation";

const router = Router();

router.post("/", async (req: Request, res: Response) => {
  try {
    const { route_id, location, heading_degrees, obstacles, speed } =
      req.body;

    if (!location || !obstacles) {
      res.status(400).json({ error: "Missing location or obstacles" });
      return;
    }

    const response = await getNavigationInstruction({
      route_id,
      location,
      heading_degrees,
      obstacles,
      speed,
    });

    res.json(response);
  } catch (err) {
    console.error("Navigation error:", err);
    res.status(500).json({ error: "Internal server error" });
  }
});

export default router;
