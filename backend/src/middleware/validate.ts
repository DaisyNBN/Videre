import { NextFunction, Request, Response } from "express";
import { z } from "zod";
import { ApiResponse } from "../ApiResponse";

type Source = "body" | "query" | "params";

type Schema = z.ZodTypeAny;

function validate(source: Source, schema: Schema) {
    return (req: Request, res: Response, next: NextFunction): void => {
        const parsed = schema.safeParse(req[source]);

        if (!parsed.success) {
            res.status(400).json(
                new ApiResponse(false, `Invalid request ${source}`, {
                    issues: parsed.error.issues,
                }),
            );
            return;
        }

        if (source === "query") {
            const target = req.query as Record<string, unknown>;
            for (const key of Object.keys(target)) {
                delete target[key];
            }
            Object.assign(target, parsed.data as Record<string, unknown>);
        } else {
            (req as Request & Record<Source, unknown>)[source] = parsed.data;
        }

        next();
    };
}

export const validateBody = (schema: Schema) => validate("body", schema);
export const validateQuery = (schema: Schema) => validate("query", schema);
export const validateParams = (schema: Schema) => validate("params", schema);
