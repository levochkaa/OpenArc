import { HttpException, HttpStatus } from "@nestjs/common";

export function unauthorized(): HttpException {
  return new HttpException({ error: "unauthorized" }, HttpStatus.UNAUTHORIZED);
}

export function httpError(statusCode: number, message: string): HttpException {
  return new HttpException(message, statusCode);
}
