import * as Cloudflare from "alchemy/Cloudflare";
import { Effect } from "effect";
import { HttpRouter } from "effect/unstable/http";

import { ApiLive } from "./Http";

const compatibility = {
  flags: ["nodejs_compat"],
  date: "2026-01-01",
} satisfies NonNullable<Cloudflare.WorkerProps["compatibility"]>;

export class WorkerC extends Cloudflare.Worker<WorkerC>()(
  "WorkerC",
  {
    main: import.meta.filename,
    compatibility,
  },
  Effect.gen(function* () {
    const fetch = yield* HttpRouter.toHttpEffect(ApiLive);

    return { fetch } as const;
  }),
) {}

export default WorkerC;
