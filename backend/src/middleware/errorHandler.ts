import { NextFunction, Request, Response } from "express";
import { ZodError } from "zod";
import { ApiResponse } from "../ApiResponse";
import logger from "../services/logger";

export class HttpError extends Error {
    statusCode: number;
    details?: unknown;

    constructor(statusCode: number, message: string, details?: unknown) {
        super(message);
        this.statusCode = statusCode;
        this.details = details;
    }
}

export function errorHandler(
    err: unknown,
    _req: Request,
    res: Response,
    next: NextFunction,
): void {
    if (res.headersSent) {
        next(err);
        return;
    }

    if (err instanceof ZodError) {
        res.status(400).json(
            new ApiResponse(false, "Invalid request", {
                issues: err.issues,
            }),
        );
        return;
    }

    if (err instanceof HttpError) {
        res.status(err.statusCode).json(new ApiResponse(false, err.message, err.details));
        return;
    }

    logger.error("Unhandled error: %o", err);
    res.status(500).json(new ApiResponse(false, "Internal server error"));
}
