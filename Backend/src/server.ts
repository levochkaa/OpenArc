import { buildApp } from "./app.js";
import { config } from "./config.js";

const app = await buildApp();

const close = async () => {
  await app.close();
};

process.on("SIGTERM", () => {
  close().finally(() => process.exit(0));
});
process.on("SIGINT", () => {
  close().finally(() => process.exit(0));
});

await app.listen(config.PORT, config.HOST);
