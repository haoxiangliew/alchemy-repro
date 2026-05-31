import { Effect, FileSystem, Layer, Path } from "effect";
import { Etag, HttpPlatform } from "effect/unstable/http";
import { HttpApiBuilder, HttpApiScalar } from "effect/unstable/httpapi";

import { WorkerAApi } from "./Api";

const WorkerAGroupLive = HttpApiBuilder.group(WorkerAApi, "worker-a", (handlers) =>
  handlers
    .handle("favicon", () => Effect.void)
    .handle("hello", () => Effect.succeed("Hello via Bun! - @repro/worker-a")),
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
  HttpApiBuilder.layer(WorkerAApi),
  HttpApiScalar.layerCdn(WorkerAApi, {
    path: "/docs",
    scalar: {
      defaultOpenAllTags: true,
      showOperationId: true,
    },
  }),
).pipe(Layer.provide(WorkerAGroupLive), Layer.provide(PlatformLive));
