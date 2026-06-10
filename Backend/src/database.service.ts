import { Injectable, type OnApplicationShutdown } from "@nestjs/common";
import type pg from "pg";
import { closeDatabasePool, pool } from "./db.js";

@Injectable()
export class DatabaseService implements OnApplicationShutdown {
  connect(): Promise<pg.PoolClient> {
    return pool.connect();
  }

  query<T extends pg.QueryResultRow = pg.QueryResultRow>(
    text: string,
    params?: unknown[]
  ): Promise<pg.QueryResult<T>> {
    return pool.query<T>(text, params);
  }

  async onApplicationShutdown(): Promise<void> {
    await closeDatabasePool();
  }
}
