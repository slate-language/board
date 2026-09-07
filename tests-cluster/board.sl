// A clustered board, for `tests-cluster/cluster.sl` to drive as a child process.
//
// **It is a program and not a suite, and it starts nothing on its own.** `slate test tests-cluster`
// walks this directory and loads what is in it, so a `main()` at the foot of this file would start a
// cluster in the middle of a run: what runs it is `BOARD_CLUSTER_DIR` naming a directory to report
// into, which nothing but the suite sets.
//
// **The worker half is `wiring.sl`'s `serving`, which is exactly what `cluster.sl` runs.** What is
// different here is the store -- `tests/store.sl`'s arrays, so that a worker needs no database -- and
// two things asked of that store which a real one would not have: a listing that dawdles, so that a
// request is still in hand when the supervisor is told to stop, and a health check that publishes, so
// that one worker says something the others can hear. **Both are the store seam and not a route in
// front of the board**, which is not a detail: a request counts as in flight only once `sluice`'s
// `handle` has it, so a slow answer written in front of the api is one the drain neither knows about
// nor waits for.
//
// **Which worker answered comes off the board's own log record.** Nothing in an answer says it, and a
// route that said it would be a route this board does not have; the sink a worker installs writes its
// own number in front of every line it logs.
//
// **Every line the suite reads is one blocking append of one line**, which is what three processes
// writing one file can do without tearing each other's lines in half -- and what an unawaited promise
// inside a handler cannot promise at all.

import { cluster } from slate:cluster
import { setLevel, setSink } from logger
import { appendFileSync, writeFileSync } from slate:fs
import { env } from slate:process

import { serving, workersFrom } from "../wiring.sl"
import { board } from "../tests/store.sl"

// Where the suite is reading, and the topic the bus probe travels on.
val Where = env("BOARD_CLUSTER_DIR") ?? ""
val Probe = "probe"

// This worker's copy of the board's event hub, which is the clustered one `serving` made. **It is
// filled in after the board is built rather than handed to it**, the store that publishes being
// underneath the very hub it publishes to.
var feed = null

async main()
    // **The suite is told this program loaded at all.** A slate without `slate:cluster` refuses the
    // import above and nothing below it runs, which is how the suite tells that release apart from a
    // board that started and then broke -- one is a skip and the other is a failure.
    writeFileSync(Where + "/loaded", "yes\n")

    await cluster({ workers: workersFrom(env("BOARD_WORKERS") ?? "", 2) }, worker)

async worker(w: object)
    setLevel("info")
    setSink(r -> say("hit", string(w.workerId) + " " + r.path))

    val made = await serving(w, probed(w, board({})))

    feed = made.feed

    listening(w, made.feed)

    say("ready", string(w.workerId) + " " + string(made.served.port))

// The array store, with the two things the suite asks of it.
probed(w: object, store: object) -> object
    // **`?q=slow` and nothing else**, so that every other request through this board is as quick as it
    // would be anywhere else and only the one the drain is about waits.
    async threads(query: object)
        if query.q == "slow" then await sleep(600)

        await store.threads(query)

    async ping()
        if feed != null then feed.publish(Probe, { word: "ping", from: w.workerId })

        await store.ping()

    store with { threads: threads, ping: ping }

// What this worker hears on the board's own hub, which is what a reader attached to it would be sent.
//
// **A publisher hears itself and every other worker hears it too**, so a line names the worker that
// heard and then the one that spoke: two different numbers is an event that crossed a process.
async listening(w: object, hub: object)
    val stream = hub.subscribe(Probe, {})

    while true
        val next = await stream.next()

        if next.done then return

        say("heard", string(w.workerId) + " " + string(next.value.from))

// **The blocking form and not the promise**, which is a decision rather than an accident: a line
// written from inside a handler and never awaited is a line the suite may never see, and nothing here
// is a server whose throughput anybody is measuring.
say(name: string, line: string) = appendFileSync(Where + "/" + name, line + "\n")

if Where != "" then main()
