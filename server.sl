// The board, in one process.
//
//     slate scripts/migrate.sl
//     PORT=8080 slate server.sl
//
// With no `PG_URL` it connects wherever `psql` would -- `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`
// and `PGDATABASE` are what `pg` reads when it is given nothing.
//
// **A port of `0` asks the kernel for one, and `localPort` says which it gave**, which is what makes
// this runnable on a machine already running something on 8080. `PORT` is what a deployment sets.
//
// **`cluster.sl` beside this file is the same board on every core**, and it is what a deployment
// runs. This one is what a person developing runs: one process, one log, one thing to stop.
//
// This file is the wiring and holds no routes: `wiring.sl` is what both entry points share,
// `api/routes.sl` is the board as HTTP, `api/postgres.sl` is the SQL, and `app/` is what a page
// looks like.

import { onShutdown } from sluice
import { serve } from slate:http
import { localPort } from slate:net
import { env } from slate:process

import { assembled, logging, opened, portOf, stopping } from "./wiring.sl"

async main()
    logging()

    val got = await opened()

    if !got.ok then return

    val store = got.value
    val made = assembled(store)
    val port = portOf(env("PORT") ?? "0")
    val server = serve(port, made.app)
    val site = "http://127.0.0.1:" + string(localPort(server))

    onShutdown(() -> stopping(made.app, server, store, made.feed))

    print("the board is at " + site)

    for r in made.app.routes()
        print(r.method, r.path, r.guards)

main()
