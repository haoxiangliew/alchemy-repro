import { WorkerA } from "@repro/worker-a";
import { WorkerB } from "@repro/worker-b";
import { WorkerC } from "@repro/worker-c";
import { Stack, localState } from "alchemy";
import * as Cloudflare from "alchemy/Cloudflare";
import { Effect } from "effect";

export default Stack(
  "repro",
  {
    providers: Cloudflare.providers(),
    state: localState(),
  },
  Effect.gen(function* () {
    const workerA = yield* WorkerA;

    const workerB = yield* WorkerB;

    const workerC = yield* WorkerC;

    return { workerA, workerB, workerC };
  }),
);
