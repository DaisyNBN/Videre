import { Request, Response } from "express";
import { ApiResponse } from "../src/ApiResponse";
import { validateBody, validateParams } from "../src/middleware/validate";
import {
    landmarkIdParamsSchema,
    verifyLandmarkBodySchema,
    LandmarkIdParams,
    VerifyLandmarkBody,
} from "../src/schemas/landmarks";
import logger from "../src/services/logger";
import {
    getLandmarkVerifications,
    ProcessLandmarkError,
    verifyLandmark,
} from "../src/services/processLandmarks";

const router = require("express").Router();

router.post(
    "/:id/verify",
    validateParams(landmarkIdParamsSchema),
    validateBody(verifyLandmarkBodySchema),
    async (req: Request, res: Response) => {
        const { id: landmarkId } = req.params as LandmarkIdParams;
        const body = req.body as VerifyLandmarkBody;

        try {
            const result = await verifyLandmark({
                landmarkId,
                verifiedBy: body.verifiedBy,
                status: body.status,
                notes: body.notes,
            });

            return res
                .status(201)
                .json(new ApiResponse(true, "Landmark verification saved", result));
        } catch (error) {
            if (error instanceof ProcessLandmarkError) {
                return res
                    .status(error.statusCode)
                    .json(new ApiResponse(false, error.message));
            }

            logger.error(
                "Unexpected landmark verification error for %s: %o",
                landmarkId,
                error,
            );
            return res
                .status(500)
                .json(new ApiResponse(false, "Failed to verify landmark"));
        }
    },
);

router.get(
    "/:id/verifications",
    validateParams(landmarkIdParamsSchema),
    async (req: Request, res: Response) => {
        const { id: landmarkId } = req.params as LandmarkIdParams;

        try {
            const verifications = await getLandmarkVerifications(landmarkId);
            return res.json(new ApiResponse(true, "Landmark verifications fetched", verifications));
        } catch (error) {
            if (error instanceof ProcessLandmarkError) {
                return res
                    .status(error.statusCode)
                    .json(new ApiResponse(false, error.message));
            }

            logger.error(
                "Unexpected verification history error for %s: %o",
                landmarkId,
                error,
            );
            return res
                .status(500)
                .json(new ApiResponse(false, "Failed to fetch verifications"));
        }
    },
);


export default router;