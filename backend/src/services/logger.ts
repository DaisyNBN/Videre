import winston from "winston";

const { combine, timestamp, errors, splat, json, colorize, printf } =
    winston.format;

const logLevel = process.env.LOG_LEVEL || "info";
const isProduction = process.env.NODE_ENV === "production";

const devFormat = combine(
    colorize({ all: true }),
    timestamp({ format: "YYYY-MM-DD HH:mm:ss" }),
    errors({ stack: true }),
    splat(),
    printf(({ timestamp: ts, level, message, stack, ...meta }) => {
        const metadata = Object.keys(meta).length ? ` ${JSON.stringify(meta)}` : "";
        const details = stack || message;
        return `${ts} [${level}] ${details}${metadata}`;
    }),
);

const prodFormat = combine(timestamp(), errors({ stack: true }), splat(), json());

export const logger = winston.createLogger({
    level: logLevel,
    format: isProduction ? prodFormat : devFormat,
    defaultMeta: { service: "videre-backend" },
    exitOnError: false,
    transports: [new winston.transports.Console()],
    exceptionHandlers: [new winston.transports.Console()],
    rejectionHandlers: [new winston.transports.Console()],
});

export default logger;
