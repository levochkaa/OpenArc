import { BadRequestException } from "@nestjs/common";
import { z, type ZodType } from "zod";

export function parseRequest<T>(schema: ZodType<T>, value: unknown): T {
  try {
    return schema.parse(value);
  } catch (error) {
    if (error instanceof z.ZodError) {
      throw new BadRequestException({
        statusCode: 400,
        error: "Bad Request",
        message: error.issues.map(formatIssue).join("; ")
      });
    }

    throw error;
  }
}

function formatIssue(issue: z.core.$ZodIssue): string {
  const path = issue.path.length > 0 ? issue.path.join(".") : "body";
  return `${path}: ${issue.message}`;
}
