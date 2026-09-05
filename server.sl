// The board.
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
// This file is the wiring and holds no routes: `api/routes.sl` is the board as HTTP, `api/postgres.sl`
// is the SQL, and `app/` is what a page looks like.

import { onShutdown } from sluice
import { info, setLevel, setSink, text as asLine } from logger
import { serve } from slate:http
import { localPort } from slate:net
import { env, stderr } from slate:process
import { randomBytes } from slate:crypto
import { base64urlEncode } from slate:url

import { application } from "./api/routes.sl"
import { configuration, postgres } from "./api/postgres.sl"
import { sessionStore } from "./api/sessions.sl"

async main()
    setLevel("info")
    setSink(written)

    val opened = await postgres(configuration())

    if !opened.ok
        print("no database:", opened.error)
        print("say where one is: PG_URL=postgres://user:secret@host/database")
        print("and put the schema in it first: slate scripts/migrate.sl")

        return

    val store = opened.value

    // **The session store is a wrapper over `sluice`'s `memoryStore`** so that the admin page can list
    // and revoke -- see `api/sessions.sl`, which also says what the same three functions look like over
    // a table. A fleet wants that one; one machine wants this.
    val sessions = sessionStore({})
    val app = application(store, sessions, { secret: secret(), sink: said, trustProxy: behindProxy() })

    val port = portOf(env("PORT") ?? "0")
    val server = serve(port, app)
    val site = "http://127.0.0.1:" + string(localPort(server))

    // **How a server under a deployment stops**: `SIGTERM` arrives, new requests are refused, what is
    // in hand finishes, and only then is the socket let go. Doing them in any other order lets a
    // request in.
    onShutdown(() -> stopping(app, server, store))

    print("the board is at " + site)

    for r in app.routes()
        print(r.method, r.path, r.guards)

// Whether something in front of this server says who the client is.
//
// **It is off unless it is asked for, and asking for it is a promise about the deployment**: with it
// on, the rate limit believes `x-forwarded-for`, which is text anybody may write -- so a board that
// sets it with nothing in front of it has a limit every client can walk round by inventing a header.
// The `Caddyfile` beside this file is the other half of the promise: `header_up X-Forwarded-For
// {remote_host}` REPLACES whatever a client sent rather than appending to it.
behindProxy() -> boolean = (env("BOARD_BEHIND_PROXY") ?? "") == "1"

// **`integer` CONVERTS a number and `number` READS one out of text**, and an environment
// variable is text -- `integer("8080")` faults.
portOf(said: string) -> integer
    val n = number(said)

    if n is integer && n >= 0 then n else 0

async stopping(app: object, server, store: object)
    val drained = await app.drain(server, { grace: 10000 })

    // **`cut` is how many requests were still running when the grace ran out**, which is the number
    // that says a grace is too short or a handler too slow -- and neither is visible unless it is
    // printed.
    print("drained:", drained)

    store.close()

// **The guard hands a sink a record and the `logger` package takes one**, so there is nothing between
// them and no line of text is built in the wrong place. `id=` on the line is `requestId`'s.
said(r: object) = info("request", r)

written(r: object) = stderr(asLine(r) + "\n")

// The key a session cookie is signed with.
//
// **A generated one means every restart signs everybody out**, which is right for a machine somebody
// is developing on and wrong for anything else -- so it is said out loud rather than left to be
// discovered when a deployment's users are logged out by a rolling restart.
secret() -> string
    val said = env("BOARD_SECRET") ?? null

    if said != null then return said

    stderr("no BOARD_SECRET: signing sessions with a key this run made up, so a restart signs everybody out\n")

    base64urlEncode(randomBytes(32))

main()
