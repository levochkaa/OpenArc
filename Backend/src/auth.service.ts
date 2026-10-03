import { Injectable } from "@nestjs/common";
import { createRemoteJWKSet, jwtVerify, SignJWT } from "jose";
import { z } from "zod";
import { config } from "./config.js";
import { unauthorized } from "./http.js";

const AppleIdentity = z.object({
  appleSubject: z.string().min(1),
  email: z.string().email().optional()
});

export type AppleIdentity = z.infer<typeof AppleIdentity>;

@Injectable()
export class AuthService {
  private readonly appleJWKS = createRemoteJWKSet(new URL("https://appleid.apple.com/auth/keys"));
  private readonly jwtSecret = new TextEncoder().encode(config.JWT_SECRET);

  async verifyAppleIdentityToken(identityToken: string): Promise<AppleIdentity> {
    const result = await jwtVerify(identityToken, this.appleJWKS, {
      issuer: "https://appleid.apple.com",
      audience: config.APPLE_CLIENT_IDS
    });

    const appleSubject = result.payload.sub;
    if (!appleSubject) {
      throw new Error("Apple identity token has no subject");
    }

    const email = typeof result.payload.email === "string" ? result.payload.email : undefined;
    return AppleIdentity.parse({ appleSubject, email });
  }

  async issueAccessToken(userID: string): Promise<string> {
    return new SignJWT({})
      .setProtectedHeader({ alg: "HS256" })
      .setSubject(userID)
      .setIssuer(config.JWT_ISSUER)
      .setAudience(config.JWT_AUDIENCE)
      .setIssuedAt()
      .setExpirationTime("30d")
      .sign(this.jwtSecret);
  }

  async verifyAccessToken(token: string): Promise<string> {
    const result = await jwtVerify(token, this.jwtSecret, {
      issuer: config.JWT_ISSUER,
      audience: config.JWT_AUDIENCE
    });

    if (!result.payload.sub) {
      throw new Error("Access token has no subject");
    }

    return result.payload.sub;
  }

  async userIDFromAuthorizationHeader(header: string | undefined): Promise<string> {
    if (!header?.startsWith("Bearer ")) {
      throw unauthorized();
    }

    try {
      return await this.verifyAccessToken(header.slice("Bearer ".length));
    } catch {
      throw unauthorized();
    }
  }
}
