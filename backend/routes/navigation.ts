import { Request, Response, Router } from "express";
import { ApiResponse } from "../src/ApiResponse";
import { validateBody } from "../src/middleware/validate";
import logger from "../src/services/logger";
import {
  generateNavigationRoute,
  generateNavigationRouteFromCoordinates,
  generateNavigationRouteToRoom,
  getNavigationInstruction,
  NavigationError,
  rerouteNavigation,
} from "../src/services/processNavigation";
import { NavRequest } from "../src/types";
import {
  navigationInstructionBodySchema,
  NavigationInstructionBody,
  navigationRerouteBodySchema,
  NavigationRerouteBody,
  navigationRouteBodySchema,
  navigationRouteFromCoordinatesBodySchema,
  navigationRouteToRoomBodySchema,
  NavigationRouteBody,
  NavigationRouteFromCoordinatesBody,
  NavigationRouteToRoomBody,
} from "../src/schemas/navigation";

const router = Router();

function buildInstructionRequest(body: NavigationInstructionBody): NavRequest {
  const routeIdRaw =
    body.route_id ?? body.routeId ?? "";
  const mapPositionRaw =
    body.map_position ?? body.mapPosition;

  return {
    route_id: routeIdRaw,
    location: body.location,
    map_position: mapPositionRaw,
    heading_degrees:
      body.heading_degrees ?? body.headingDegrees ?? 0,
    obstacles: body.obstacles,
    speed: body.speed,
    speed_mps: body.speed_mps ?? body.speedMps,
  };
}

async function handleInstructionRequest(req: Request, res: Response): Promise<void> {
  try {
    const instructionRequest = buildInstructionRequest(
      req.body as NavigationInstructionBody,
    );

    const response = await getNavigationInstruction(instructionRequest);

    res.json(new ApiResponse(true, "Navigation instruction generated", response));
  } catch (err) {
    if (err instanceof NavigationError) {
      res.status(err.statusCode).json(new ApiResponse(false, err.message));
      return;
    }

    logger.error("Navigation instruction error: %o", err);
    res.status(500).json(new ApiResponse(false, "Internal server error"));
  }
}

router.post("/", validateBody(navigationInstructionBodySchema), handleInstructionRequest);

router.post(
  "/instructions",
  validateBody(navigationInstructionBodySchema),
  handleInstructionRequest,
);

router.post(
  "/routes/from-coordinates",
  validateBody(navigationRouteFromCoordinatesBodySchema),
  async (req: Request, res: Response) => {
    const body = req.body as NavigationRouteFromCoordinatesBody;

    try {
      const route = await generateNavigationRouteFromCoordinates({
        mapId: body.mapId,
        start: body.start,
        end: body.end,
        blockedNodeIds: body.blockedNodeIds,
      });

      return res.status(201).json(new ApiResponse(true, "Route generated from coordinates", route));
    } catch (err) {
      if (err instanceof NavigationError) {
        return res.status(err.statusCode).json(new ApiResponse(false, err.message));
      }

      logger.error("Navigation route generation from coordinates error: %o", err);
      return res.status(500).json(new ApiResponse(false, "Failed to generate route from coordinates"));
    }
  },
);

router.post(
  "/routes/to-room",
  validateBody(navigationRouteToRoomBodySchema),
  async (req: Request, res: Response) => {
    const body = req.body as NavigationRouteToRoomBody;

    try {
      const route = await generateNavigationRouteToRoom({
        mapId: body.mapId,
        start: body.start,
        destinationLabel: body.destinationLabel,
        blockedNodeIds: body.blockedNodeIds,
      });

      return res.status(201).json(new ApiResponse(true, "Route generated to destination room", route));
    } catch (err) {
      if (err instanceof NavigationError) {
        return res.status(err.statusCode).json(new ApiResponse(false, err.message));
      }

      logger.error("Navigation room route generation error: %o", err);
      return res.status(500).json(new ApiResponse(false, "Failed to generate route to destination room"));
    }
  },
);

router.post("/routes", validateBody(navigationRouteBodySchema), async (req: Request, res: Response) => {
  const body = req.body as NavigationRouteBody;

  try {
    const route = await generateNavigationRoute({
      mapId: body.mapId,
      startNodeId: body.startNodeId,
      endNodeId: body.endNodeId,
      blockedNodeIds: body.blockedNodeIds,
    });

    return res.status(201).json(new ApiResponse(true, "Route generated", route));
  } catch (err) {
    if (err instanceof NavigationError) {
      return res.status(err.statusCode).json(new ApiResponse(false, err.message));
    }

    logger.error("Navigation route generation error: %o", err);
    return res.status(500).json(new ApiResponse(false, "Failed to generate route"));
  }
});

router.post("/reroute", validateBody(navigationRerouteBodySchema), async (req: Request, res: Response) => {
  const body = req.body as NavigationRerouteBody;

  try {
    const reroute = await rerouteNavigation({
      mapId: body.mapId,
      startNodeId: body.startNodeId,
      endNodeId: body.endNodeId,
      blockedNodeIds: body.blockedNodeIds,
      obstacleNodeIds: body.obstacleNodeIds,
      reason: body.reason,
    });

    return res.status(201).json(new ApiResponse(true, "Route recalculated", reroute));
  } catch (err) {
    if (err instanceof NavigationError) {
      return res.status(err.statusCode).json(new ApiResponse(false, err.message));
    }

    logger.error("Navigation reroute error: %o", err);
    return res.status(500).json(new ApiResponse(false, "Failed to reroute"));
  }
});

export default router;
