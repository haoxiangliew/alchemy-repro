import { Effect, FileSystem, Path, Layer } from "effect";
import { Etag, HttpPlatform } from "effect/unstable/http";
import { HttpApiBuilder, HttpApiScalar } from "effect/unstable/httpapi";

import { WorkerBApi } from "./Api";

const WorkerBGroupLive = HttpApiBuilder.group(WorkerBApi, "worker-b", (handlers) =>
  handlers
    .handle("favicon", () => Effect.void)
    .handle("hello", () => Effect.succeed("Hello via Bun! - @repro/worker-b")),
);

// INFO: We annotate the type here because alchemy has a type hole
// that drills all the way into `alchemy.run.ts`
const PlatformLive: Layer.Layer<
  HttpPlatform.HttpPlatform | Etag.Generator | FileSystem.FileSystem | Path.Path,
  never,
  never
> = HttpPlatform.layer.pipe(
  Layer.provideMerge(Layer.mergeAll(Etag.layer, FileSystem.layerNoop({}), Path.layer)),
);

export const ApiLive = Layer.mergeAll(
  HttpApiBuilder.layer(WorkerBApi),
  HttpApiScalar.layerCdn(WorkerBApi, {
    path: "/docs",
    scalar: {
      defaultOpenAllTags: true,
      showOperationId: true,
    },
  }),
).pipe(Layer.provide(WorkerBGroupLive), Layer.provide(PlatformLive));
