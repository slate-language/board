// What the two entry points share: the log sink, the database, the board itself, and what stopping
// one means.
//
// **`server.sl` is one process and `cluster.sl` is a worker per core**, and everything above that
// difference is here -- a board is the same board however many copies of it are running. Neither
// this file nor either entry point holds a route: `api/routes.sl` is the board as HTTP,
// `api/postgres.sl` is the SQL, and `app/` is what a page looks like.
//
// **Nothing here runs at load**, which is what lets both entry points import it and what
// `tests-cluster/board.sl` relies on to run the same worker over the array store.

import { hub } from sluice
import { info, setLevel, setSink, text as asLine } from logger
import { env, stderr } from slate:process
import { randomBytes } from slate:crypto
import { base64urlEncode } from slate:url

import { application } from "./api/routes.sl"
import { configuration, postgres } from "./api/postgres.sl"
import { sessionStore } from "./api/sessions.sl"

// Where a request's log line goes, installed once per process.
export logging()
    setLevel("info")
    setSink(written)

// The database, or the three lines that say how to give it one.
//
// **Every process opens its own**, which is what a cluster of workers is: a pool per worker rather
// than one pool shared by something that cannot be shared across a process boundary.
export async opened() -> object
    val got = await postgres(configuration())

    if !got.ok
        print("no database:", got.error)
        print("say where one is: PG_URL=postgres://user:secret@host/database")
        print("and put the schema in it first: slate scripts/migrate.sl")

    got

// The board over a store: the sessions, the event hub and the application.
//
// **The hub is made here rather than left to `application`'s own default**, so that shutdown holds
// the same handle its streams were opened on and can end them instead of waiting a grace out. A
// caller with a hub of its own -- `cluster.sl`, whose hub reaches the other workers -- says so.
export assembled(store: object, options: object = {}) -> object
    // **The session store is a wrapper over `sluice`'s `memoryStore`** so that the admin page can list
    // and revoke -- see `api/sessions.sl`, which also says what the same three functions look like over
    // a table. A fleet wants that one; one machine wants this.
    val sessions = sessionStore({})
    val feed = options.feed ?? hub({ replay: 64 })
    val app = application(store, sessions, { secret: secret(), sink: said, trustProxy: behindProxy(),
                                             feed: feed })

    { app: app, feed: feed, sessions: sessions }

// **How a server under a deployment stops**: new requests are refused, what is in hand finishes, its
// event streams are ended rather than waited on, and only then is the socket let go. Doing them in
// any other order lets a request in.
//
// **`close` is an option because closing is not the same act in the two entry points.** One process
// closes the socket it opened; a worker has no socket -- the supervisor holds the only listener --
// and lets go of a port by saying so over its channel, which is what `w.serve` answers a `close` for.
export async stopping(app: object, server, store: object, feed: object, options: object = {})
    val drained = await app.drain(server, { grace: 10000, hubs: [feed] } with options)

    // **`cut` is how many requests were still running when the grace ran out, `ended` how many event
    // streams were**, which is the number that says a grace is too short or a handler too slow -- and
    // neither is visible unless it is printed.
    print("drained:", drained)

    store.close()

// Whether something in front of this server says who the client is.
//
// **It is off unless it is asked for, and asking for it is a promise about the deployment**: with it
// on, the rate limit believes `x-forwarded-for`, which is text anybody may write -- so a board that
// sets it with nothing in front of it has a limit every client can walk round by inventing a header.
// The `Caddyfile` beside this file is the other half of the promise: `header_up X-Forwarded-For
// {remote_host}` REPLACES whatever a client sent rather than appending to it.
export behindProxy() -> boolean = (env("BOARD_BEHIND_PROXY") ?? "") == "1"

// **`integer` CONVERTS a number and `number` READS one out of text**, and an environment
// variable is text -- `integer("8080")` faults.
export portOf(said: string) -> integer
    val n = number(said)

    if n is integer && n >= 0 then n else 0

// How many workers a cluster runs: what `BOARD_WORKERS` says, and a worker per core otherwise.
//
// **Text that is not a positive whole number is the default rather than a refusal**, exactly as a
// port that is not a number is: a deployment that mistypes a count gets the machine it paid for and
// not a board that will not start.
export workersFrom(said: string, cores: integer) -> integer
    val n = number(said)

    if n is integer && n > 0 then n else cores

// **The guard hands a sink a record and the `logger` package takes one**, so there is nothing between
// them and no line of text is built in the wrong place. `id=` on the line is `requestId`'s.
export said(r: object) = info("request", r)

// **A line goes to `stderr` and not to `print`**, which matters more under a supervisor than it does
// under one process: standard output is a buffer when it is a file rather than a terminal, and a
// program that never ends never flushes one -- so a board whose log went to `print` would write
// nothing at all into a deployment's log file until the day it stopped.
export written(r: object) = stderr(asLine(r) + "\n")

// The key a session cookie is signed with.
//
// **A generated one means every restart signs everybody out**, which is right for a machine somebody
// is developing on and wrong for anything else -- so it is said out loud rather than left to be
// discovered when a deployment's users are logged out by a rolling restart. **Under `cluster.sl` it
// is worse than that and that file refuses to start without one**: each worker would make up a key of
// its own, so a cookie signed by the worker that answered a sign-in is a forgery to the other three.
export secret() -> string
    val said = env("BOARD_SECRET") ?? null

    if said != null then return said

    stderr("no BOARD_SECRET: signing sessions with a key this run made up, so a restart signs everybody out\n")

    base64urlEncode(randomBytes(32))

// -- the worker half, which nothing but a cluster reaches -----------------------------------------

// The topic a board's events travel between workers on.
val Bus = "board:events"

// The board's event hub, with the other workers on the far side of it.
//
// **A reply posted on one worker has to reach the readers attached to the others**, and under a
// supervisor those are three other processes: `sluice`'s hub fans an event out to the subscribers in
// THIS program, which is a quarter of the board. So the hub handed to `application` is this one --
// the same five functions, with `publish` also saying it upstream, where the supervisor fans it out
// to every other worker's `subscribe`. **A publisher does not hear itself**, which is what keeps one
// post from becoming an echo.
//
// **The replay ring is still this worker's own.** A hub given `replay: 64` numbers its events itself,
// so an id means something only to the worker that made it, and a reader reconnecting with a
// `Last-Event-ID` reaches whichever worker the supervisor gives it. What survives a cluster is the
// live fan-out; what does not is the replay a reconnection asks for, and a board that needs that
// across workers needs the ids to come from something both workers can read.
export clusteredFeed(w: object, feed: object) -> object
    w.subscribe(Bus, said -> feed.publish(said.topic, said.value))

    publish(topic: string, value)
        feed.publish(topic, value)
        w.publish(Bus, { topic: topic, value: value })

    { publish: publish, subscribe: feed.subscribe, count: feed.count, open: feed.open,
      endAll: feed.endAll }

// One worker: the board, served on the port the deployment named, and drained when the supervisor
// says so.
//
// **The supervisor holds the only listening socket** under the default scheduling, so a worker asking
// for port `0` learns which port the kernel gave only when it is told -- which is why `w.serve`
// answers `{ port, close }` rather than a server, and why the port is worth reporting from here.
//
// **What it answers is the board as well as the port**, because a caller with something to add to
// either has nowhere else to reach it: `tests-cluster/`'s harness puts three probe routes on the
// app it gets back, which is what lets a suite ask a real socket which of three processes answered.
export async serving(w: object, store: object) -> object
    val made = assembled(store, { feed: clusteredFeed(w, hub({ replay: 64 })) })
    val served = await w.serve(portOf(env("PORT") ?? "0"), made.app)

    w.onShutdown(() -> stopping(made.app, served, store, made.feed, { close: s -> s.close() }))

    made with { served: served }
