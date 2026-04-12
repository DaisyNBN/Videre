import { Request, Response } from "express";
import { ApiResponse } from "../src/ApiResponse";
import {
  validateBody,
  validateParams,
  validateQuery,
} from "../src/middleware/validate";
import {
  mapContributionsCreateBodySchema,
  mapContributionsListQuerySchema,
  mapCreateBodySchema,
  mapCreateLandmarkBodySchema,
  mapCreateNodeBodySchema,
  mapIdParamsSchema,
  mapLandmarkParamsSchema,
  mapListQuerySchema,
  mapUpdateLandmarkBodySchema,
  MapContributionsCreateBody,
  MapContributionsListQuery,
  MapCreateBody,
  MapCreateLandmarkBody,
  MapCreateNodeBody,
  MapIdParams,
  MapLandmarkParams,
  MapListQuery,
  MapUpdateLandmarkBody,
} from "../src/schemas/maps";
import logger from "../src/services/logger";
import {
  createMap,
  createMapNode,
  createMapVersion,
  getMapById,
  getMapGraph,
  listMaps,
  ProcessMapError,
} from "../src/services/processMap";
import {
  createMapLandmark,
  deleteMapLandmark,
  getMapVerificationSummary,
  listMapLandmarks,
  ProcessLandmarkError,
  updateMapLandmark,
} from "../src/services/processLandmarks";
import {
  createMapContribution,
  listMapContributions,
  ProcessContributionError,
} from "../src/services/processContributions";

const router = require("express").Router();

router.post("/", validateBody(mapCreateBodySchema), async (req: Request, res: Response) => {
  const body = req.body as MapCreateBody;

  try {
    const map = await createMap({
      scanId: body.scanId,
      roomName: body.roomName,
      points: body.points,
      landmarks: body.landmarks,
      createdBy: body.createdBy,
    });

    return res
      .status(201)
      .json(new ApiResponse(true, "Map created", map));
  } catch (error) {
    if (error instanceof ProcessMapError) {
      return res
        .status(error.statusCode)
        .json(new ApiResponse(false, error.message));
    }

    logger.error("Unexpected map creation error: %o", error);
    return res
      .status(500)
      .json(new ApiResponse(false, "Failed to create map"));
  }
});

router.get("/", validateQuery(mapListQuerySchema), async (req: Request, res: Response) => {
  const { roomName, version, limit, offset } = mapListQuerySchema.parse(
    req.query,
  ) as MapListQuery;

  try {
    const result = await listMaps({
      roomName,
      version,
      limit,
      offset,
    });

    return res.json(new ApiResponse(true, "Maps fetched", result));
  } catch (error) {
    if (error instanceof ProcessMapError) {
      return res
        .status(error.statusCode)
        .json(new ApiResponse(false, error.message));
    }

    logger.error("Unexpected maps list error: %o", error);
    return res
      .status(500)
      .json(new ApiResponse(false, "Failed to list maps"));
  }
});

router.get("/:id", validateParams(mapIdParamsSchema), async (req: Request, res: Response) => {
  const { id: mapId } = req.params as MapIdParams;

  try {
    const map = await getMapById(mapId);
    return res.json(new ApiResponse(true, "Map fetched", map));
  } catch (error) {
    if (error instanceof ProcessMapError) {
      return res
        .status(error.statusCode)
        .json(new ApiResponse(false, error.message));
    }

    logger.error("Unexpected map fetch error for %s: %o", mapId, error);
    return res
      .status(500)
      .json(new ApiResponse(false, "Failed to fetch map"));
  }
});

router.get("/:id/graph", validateParams(mapIdParamsSchema), async (req: Request, res: Response) => {
  const { id: mapId } = req.params as MapIdParams;

  try {
    const graph = await getMapGraph(mapId);
    return res.json(new ApiResponse(true, "Map graph fetched", graph));
  } catch (error) {
    if (error instanceof ProcessMapError) {
      return res
        .status(error.statusCode)
        .json(new ApiResponse(false, error.message));
    }

    logger.error("Unexpected graph fetch error for %s: %o", mapId, error);
    return res
      .status(500)
      .json(new ApiResponse(false, "Failed to fetch map graph"));
  }
});

router.post(
  "/:id/nodes",
  validateParams(mapIdParamsSchema),
  validateBody(mapCreateNodeBodySchema),
  async (req: Request, res: Response) => {
    const { id: mapId } = req.params as MapIdParams;
    const body = req.body as MapCreateNodeBody;

    try {
      const node = await createMapNode({
        mapId,
        type: body.type,
        label: body.label,
        x: body.x,
        y: body.y,
        z: body.z,
        autoConnect: body.autoConnect,
        maxConnectionDistanceMeters: body.maxConnectionDistanceMeters,
      });

      return res
        .status(201)
        .json(new ApiResponse(true, "Map node created", node));
    } catch (error) {
      if (error instanceof ProcessMapError) {
        return res
          .status(error.statusCode)
          .json(new ApiResponse(false, error.message));
      }

      logger.error("Unexpected map node creation error for map %s: %o", mapId, error);
      return res
        .status(500)
        .json(new ApiResponse(false, "Failed to create map node"));
    }
  },
);

router.post("/:id/version", validateParams(mapIdParamsSchema), async (req: Request, res: Response) => {
  const { id: mapId } = req.params as MapIdParams;

  try {
    const versionedMap = await createMapVersion(mapId);
    return res
      .status(201)
      .json(new ApiResponse(true, "Map version created", versionedMap));
  } catch (error) {
    if (error instanceof ProcessMapError) {
      return res
        .status(error.statusCode)
        .json(new ApiResponse(false, error.message));
    }

    logger.error("Unexpected map versioning error for %s: %o", mapId, error);
    return res
      .status(500)
      .json(new ApiResponse(false, "Failed to create map version"));
  }
});

router.post(
  "/:id/landmarks",
  validateParams(mapIdParamsSchema),
  validateBody(mapCreateLandmarkBodySchema),
  async (req: Request, res: Response) => {
    const { id: mapId } = req.params as MapIdParams;
    const body = req.body as MapCreateLandmarkBody;

    try {
      const landmark = await createMapLandmark({
        mapId,
        type: body.type,
        label: body.label,
        x: body.x,
        y: body.y,
        z: body.z,
        headingDegrees: body.headingDegrees,
        source: body.source,
        confidence: body.confidence,
      });

      return res
        .status(201)
        .json(new ApiResponse(true, "Landmark created", landmark));
    } catch (error) {
      if (error instanceof ProcessLandmarkError || error instanceof ProcessMapError) {
        return res
          .status(error.statusCode)
          .json(new ApiResponse(false, error.message));
      }

      logger.error("Unexpected landmark creation error for map %s: %o", mapId, error);
      return res
        .status(500)
        .json(new ApiResponse(false, "Failed to create landmark"));
    }
  },
);

router.get("/:id/landmarks", validateParams(mapIdParamsSchema), async (req: Request, res: Response) => {
  const { id: mapId } = req.params as MapIdParams;

  try {
    const landmarks = await listMapLandmarks(mapId);
    return res.json(new ApiResponse(true, "Landmarks fetched", landmarks));
  } catch (error) {
    if (error instanceof ProcessLandmarkError || error instanceof ProcessMapError) {
      return res
        .status(error.statusCode)
        .json(new ApiResponse(false, error.message));
    }

    logger.error("Unexpected landmarks fetch error for map %s: %o", mapId, error);
    return res
      .status(500)
      .json(new ApiResponse(false, "Failed to fetch landmarks"));
  }
});

router.patch(
  "/:id/landmarks/:landmarkId",
  validateParams(mapLandmarkParamsSchema),
  validateBody(mapUpdateLandmarkBodySchema),
  async (req: Request, res: Response) => {
    const { id: mapId, landmarkId } = req.params as MapLandmarkParams;
    const body = req.body as MapUpdateLandmarkBody;

    try {
      const updated = await updateMapLandmark({
        mapId,
        landmarkId,
        type: body.type,
        label: body.label,
        x: body.x,
        y: body.y,
        z: body.z,
        headingDegrees: body.headingDegrees,
        source: body.source,
      });

      return res.json(new ApiResponse(true, "Landmark updated", updated));
    } catch (error) {
      if (error instanceof ProcessLandmarkError || error instanceof ProcessMapError) {
        return res
          .status(error.statusCode)
          .json(new ApiResponse(false, error.message));
      }

      logger.error(
        "Unexpected landmark update error for map %s landmark %s: %o",
        mapId,
        landmarkId,
        error,
      );
      return res
        .status(500)
        .json(new ApiResponse(false, "Failed to update landmark"));
    }
  },
);

router.delete(
  "/:id/landmarks/:landmarkId",
  validateParams(mapLandmarkParamsSchema),
  async (req: Request, res: Response) => {
    const { id: mapId, landmarkId } = req.params as MapLandmarkParams;

    try {
      await deleteMapLandmark({ mapId, landmarkId });
      return res.json(new ApiResponse(true, "Landmark deleted"));
    } catch (error) {
      if (error instanceof ProcessLandmarkError || error instanceof ProcessMapError) {
        return res
          .status(error.statusCode)
          .json(new ApiResponse(false, error.message));
      }

      logger.error(
        "Unexpected landmark delete error for map %s landmark %s: %o",
        mapId,
        landmarkId,
        error,
      );
      return res
        .status(500)
        .json(new ApiResponse(false, "Failed to delete landmark"));
    }
  },
);

router.get("/:id/verification-summary", validateParams(mapIdParamsSchema), async (req: Request, res: Response) => {
  const { id: mapId } = req.params as MapIdParams;

  try {
    const summary = await getMapVerificationSummary(mapId);
    return res.json(new ApiResponse(true, "Verification summary fetched", summary));
  } catch (error) {
    if (error instanceof ProcessLandmarkError || error instanceof ProcessMapError) {
      return res
        .status(error.statusCode)
        .json(new ApiResponse(false, error.message));
    }

    logger.error(
      "Unexpected verification summary error for map %s: %o",
      mapId,
      error,
    );
    return res
      .status(500)
      .json(new ApiResponse(false, "Failed to fetch verification summary"));
  }
});

router.post(
  "/:id/contributions",
  validateParams(mapIdParamsSchema),
  validateBody(mapContributionsCreateBodySchema),
  async (req: Request, res: Response) => {
    const { id: mapId } = req.params as MapIdParams;
    const body = req.body as MapContributionsCreateBody;

    try {
      const result = await createMapContribution({
        mapId,
        contributionType: body.contributionType ?? body.type,
        payload: body.payload,
        createdBy: body.createdBy,
        status: body.status,
        notes: body.notes,
        createVersionOnAccept: body.createVersionOnAccept,
      });

      return res
        .status(201)
        .json(new ApiResponse(true, "Contribution created", result));
    } catch (error) {
      if (
        error instanceof ProcessContributionError ||
        error instanceof ProcessMapError
      ) {
        return res
          .status(error.statusCode)
          .json(new ApiResponse(false, error.message));
      }

      logger.error("Unexpected contribution create error for map %s: %o", mapId, error);
      return res
        .status(500)
        .json(new ApiResponse(false, "Failed to create contribution"));
    }
  },
);

router.get(
  "/:id/contributions",
  validateParams(mapIdParamsSchema),
  validateQuery(mapContributionsListQuerySchema),
  async (req: Request, res: Response) => {
    const { id: mapId } = req.params as MapIdParams;
    const { status, limit, offset } = mapContributionsListQuerySchema.parse(
      req.query,
    ) as MapContributionsListQuery;

    try {
      const result = await listMapContributions({
        mapId,
        status,
        limit,
        offset,
      });

      return res.json(new ApiResponse(true, "Contributions fetched", result));
    } catch (error) {
      if (
        error instanceof ProcessContributionError ||
        error instanceof ProcessMapError
      ) {
        return res
          .status(error.statusCode)
          .json(new ApiResponse(false, error.message));
      }

      logger.error("Unexpected contribution list error for map %s: %o", mapId, error);
      return res
        .status(500)
        .json(new ApiResponse(false, "Failed to fetch contributions"));
    }
  },
);

export default router;
