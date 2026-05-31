import { Schema } from "effect";
import {
  HttpApi,
  HttpApiEndpoint,
  HttpApiGroup,
  HttpApiSchema,
  OpenApi,
} from "effect/unstable/httpapi";

const FaviconEndpoint = HttpApiEndpoint.get("favicon", "/favicon.ico", {
  success: HttpApiSchema.NoContent,
}).annotate(OpenApi.Exclude, true);

const HelloEndpoint = HttpApiEndpoint.get("hello", "/", {
  success: Schema.String.pipe(HttpApiSchema.asText()),
});

const WorkerCGroup = HttpApiGroup.make("worker-c").add(FaviconEndpoint).add(HelloEndpoint);

export const WorkerCApi = HttpApi.make("WorkerC").add(WorkerCGroup);
