// The board on every core, which is how a deployment runs it.
//
//     slate scripts/migrate.sl
//     PORT=8080 BOARD_SECRET=a-long-random-string BOARD_WORKERS=4 slate cluster.sl
//
// **One slate program is one event loop on one thread**, so a machine with eight cores running
// `server.sl` is using an eighth of what it was paid for. `slate:cluster` is the answer: the
// supervisor runs this program again once per core, holds the only listening socket, and hands each
// connection it accepts to the next worker. `BOARD_WORKERS` is how a deployment says a number other
// than `cpus()`.
//
// **What this file is, is `server.sl` with a supervisor over it.** The board, the database, the
// session store and the drain are all `wiring.sl`'s and are the same in both -- what is here is the
// count, the two signals a deployment sends, and the one thing a cluster needs that one process does
// not, which is a key every worker agrees on.
//
// | signal | |
// |---|---|
// | `SIGTERM`, `SIGINT` | every worker drains what it has in hand and the cluster exits |
// | `SIGHUP` | the workers are replaced one at a time, the replacement serving before the one it replaces is asked to go |
//
// **A worker that dies is started again** with a backoff after repeated quick deaths, so a board that
// faults on a row nobody expected is a board that is still up.
//
// **Every statement above the `cluster` call runs in every process**, a worker being another copy of
// this program: which half a process is, is settled before a statement of it runs. So the check at the
// foot of this file is made four times over and the board is opened inside the worker function, where
// four copies of it is the point.

import { cluster } from slate:cluster
import { cpus, env, exit, stderr } from slate:process

import { logging, opened, serving, workersFrom } from "./wiring.sl"

async main()
    logging()

    await cluster({ workers: workersFrom(env("BOARD_WORKERS") ?? "", cpus()), primary: supervising },
        worker)

// The supervisor, which serves nothing and watches everything.
//
// **The lines go to `stderr`**, because standard output is a buffer where it is a file rather than a
// terminal and a supervisor is a program that does not end -- so a restart printed with `print` is a
// restart a deployment's log finds out about the day the board stops.
supervising(sup: object)
    stderr("the board is supervising " + string(sup.workers) + " workers\n")

    sup.onWorkerExit(id -> stderr("worker " + string(id) + " went; starting another\n"))

// One worker: its own connection pool, its own copy of the board, and the port the supervisor holds.
async worker(w: object)
    val got = await opened()

    // **A worker that cannot reach the database ends**, and the supervisor starts another -- with the
    // backoff that keeps a board whose database is down from spinning a core while it is. Carrying on
    // without one would be a worker answering every request with a fault.
    if !got.ok then return

    val made = await serving(w, got.value)

    stderr("worker " + string(w.workerId) + " is serving " + string(made.served.port) + "\n")

// **A cluster without `BOARD_SECRET` cannot sign anybody in and would not say so.** Each worker makes
// its own key where there is none, so the cookie the worker that answered a sign-in handed out is a
// forgery to the other three, and what a reader sees is a board that signs them out every few clicks.
// One process gets a warning for this; four get a refusal.
//
// **It is decided out here rather than inside `main`**, because `exit` inside an `async` function is
// refused -- *"a test may not stop the run it is part of"* -- and a deployment reads the status of the
// program it started.
if (env("BOARD_SECRET") ?? "") == ""
    stderr("no BOARD_SECRET: a cluster signs a cookie in one worker and reads it in another, so " +
           "every worker needs the same key\n")

    exit(1)

main()
