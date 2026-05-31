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

const WorkerAGroup = HttpApiGroup.make("worker-a").add(FaviconEndpoint).add(HelloEndpoint);

export const WorkerAApi = HttpApi.make("WorkerA").add(WorkerAGroup);
