// The board under `slate:cluster`, driven as a child process over a real socket.
//
//     slate test tests-cluster
//
// **This is a suite of its own for the reason `tests-dom/` is one.** Both files here name
// `slate:cluster` and `slate:process`'s `spawn`, and a slate that has neither refuses the import
// rather than answering a question -- so `slate test tests` walking this directory would fail with
// the very refusal that says the release is too old, and there is no conditional import to write it
// around. It runs under the interpreter; there is nothing here a browser could be asked.
//
// **This is the one suite that binds a port and starts a program.** Everything in `tests/` drives
// `app.handle`, which is a function of a value and can say nothing at all about a supervisor: what is
// asked here is which of three processes answered, whether a killed worker comes back, whether an
// event crosses from one worker to another, and what the two signals a deployment sends actually do.
// `tests-cluster/board.sl` is the program being driven and says how it reports.
//
// **Nothing here reads standard output.** A child's output is inherited rather than captured, and a
// program that never ends never flushes a `print` into a file anyway -- so the worker writes a line
// per fact into a directory of its own and this file reads the directory.
//
// **A watchdog is armed and cleared in the body**, never in a hook: the runner's per-test drain
// happens before a `@teardown`, so a timer left armed is waited out before the hook that would have
// cleared it is ever called. Every cluster started here is stopped in the body for the same reason --
// a live child keeps this program alive, and a test that threw before the kill is a run that hangs
// rather than a test that failed.

import { connect, close, onData, onError, send } from slate:net
import { env, run, spawn } from slate:process
import { exists, mkdir, readDir, readFile, remove, rmdir } from slate:fs

// The longest any one of these may take before it is a failure rather than a wait.
val Grace = 30000

// What a host without `slate:cluster` is told it is waiting for.
val Waiting = "waiting on a slate that has `slate:cluster`: there is no supervisor to drive without it"

@test
async A_REQUEST_IS_ANSWERED_BY_WHICHEVER_WORKER_IS_NEXT()
    if !(await driving("spread", 3, spread)) then skip(Waiting)

@test
async A_WORKER_THAT_DIES_IS_REPLACED_AND_THE_BOARD_KEEPS_ANSWERING()
    if !(await canRun()) then skip("waiting on `run` on this host: a worker cannot be killed without one")

    if !(await driving("restart", 3, restart)) then skip(Waiting)

@test
async WHAT_ONE_WORKER_PUBLISHES_EVERY_OTHER_WORKER_HEARS()
    if !(await driving("bus", 3, crossing)) then skip(Waiting)

@test
async SIGTERM_FINISHES_THE_REQUEST_IN_HAND_AND_TAKES_EVERY_WORKER_WITH_IT()
    if !(await canRun()) then skip("waiting on `run` on this host: an orphan cannot be looked for without one")

    if !(await driving("term", 2, draining)) then skip(Waiting)

@test
async SIGHUP_REPLACES_EVERY_WORKER_WITHOUT_REFUSING_A_CONNECTION()
    if !(await driving("hup", 2, rolling)) then skip(Waiting)

// -- what each of them asks ----------------------------------------------------------------------

// **Six requests and three workers**, which is a round-robin twice over. What is asserted is that
// more than one worker answered, because that is the claim; that it is all three is asserted
// separately, since a supervisor handing every connection to the same worker would pass the first.
async spread(it: object)
    for i in [1, 2, 3, 4, 5, 6]
        assertEq((await asked(it.port, "/")).status, 200, "the board answers through the supervisor")

    val who = distinct(firsts(await lines(it.where, "hit")))

    assert(who.length > 1, "six requests were all answered by one worker, so nothing is spread")
    assertEq(who.length, 3, "every worker took a turn")

// **A killed worker is a worker the supervisor starts again**, and the board answers throughout.
async restart(it: object)
    val before = await children(it.child.pid)

    assertEq(before.length, 3, "three workers were started")

    await run("kill", ["-9", before[0]], {})

    // The replacement announces itself by writing its own line, so a fourth line is a fourth worker.
    assert(await grew(it.where, "ready", 4), "the worker that was killed was never replaced")

    for i in [1, 2, 3]
        assertEq((await asked(it.port, "/")).status, 200, "the board answers while a worker is being replaced")

    val now = await children(it.child.pid)

    assertEq(now.length, 3, "the cluster is back to three workers")
    assert(!holds(now, before[0]), "the worker that was killed is still a child")

// **An event published on the worker that answered reaches the workers that did not.** The board's
// hub fans an event out to the subscribers in one process, which under a supervisor is a third of the
// board; what crosses is `wiring.sl`'s clustered hub, and a line whose hearer is not its speaker is
// the whole of the proof.
async crossing(it: object)
    assertEq((await asked(it.port, "/health")).status, 200)

    var crossed = null
    var waited = 0

    // **Its own budget, shorter than the watchdog**, so that a bus that carries nothing fails saying
    // so rather than being cut off by the alarm with a sentence about time.
    while crossed == null && waited < 10000
        for line in await lines(it.where, "heard")
            val bits = split(line, " ")

            if bits.length == 2 && bits[0] != bits[1] then crossed = line

        if crossed == null
            await sleep(50)

            waited = waited + 50

    assert(crossed != null, "nothing one worker published was heard by another")

// **`SIGTERM` finishes what is in hand.** The slow request is a real route over a store that dawdles,
// so it is counted in flight by `sluice` exactly as any other request is -- a slow answer written in
// front of the api would not be, and the drain would report `cut: 0` while cutting it off.
async draining(it: object)
    val before = await children(it.child.pid)
    val slow = asked(it.port, "/?q=slow")

    await sleep(200)

    it.child.kill("SIGTERM")

    val got = await slow

    assertEq(got.status, 200, "the request in hand was finished rather than cut off")

    val left = await it.child.exited

    assert(left != null, "the supervisor did not exit")

    for pid in before
        assert(!(await alive(pid)), "worker " + pid + " is still running after the drain")

    assertEq((await asked(it.port, "/")).status, 0, "the port is still answering after the drain")

// **`SIGHUP` replaces the workers one at a time**, the replacement serving before the one it replaces
// is asked to leave -- so a connection made in the middle of it is answered rather than refused.
async rolling(it: object)
    val was = biggest(firsts(await lines(it.where, "ready")))

    it.child.kill("SIGHUP")

    var answered = 0
    var refused = 0

    while (await lines(it.where, "ready")).length < 4 && answered + refused < 200
        val got = await asked(it.port, "/")

        if got.status == 200 then answered = answered + 1 else refused = refused + 1

    assertEq(refused, 0, "a connection was refused while the workers were being replaced")
    assert(answered > 0, "nothing was asked during the roll")

    assert(await grew(it.where, "ready", 4), "the workers were never replaced")

    for i in [1, 2, 3]
        assertEq((await asked(it.port, "/")).status, 200)

    val who = firsts(await lines(it.where, "hit"))

    assert(number(who[who.length - 1]) > was, "the board is still being answered by a worker the roll replaced")

// -- starting one, and stopping it however the test went ------------------------------------------

// **A cluster started here is stopped here.** slate has no `finally`, and a body that throws before
// the kill leaves a child holding this program open: the runner's drain then waits on a supervisor
// that nothing is going to stop, which reads as a suite that hangs rather than a test that failed.
//
// It answers whether there was a cluster to drive at all, `false` being the host that has no
// `slate:cluster` -- which is a skip and not a failure.
async driving(name: string, workers: integer, body) -> boolean
    val it = await started(name, workers)

    if it == null then return false

    var trouble = null

    try
        await within(Grace, body(it), "the cluster did not answer in time")
    catch e
        trouble = e

    await stopped(it)

    if trouble != null then throw trouble

    true

// The board as a supervisor and `workers` workers, answered once every worker says it is serving.
//
// **`PORT` is `0`**, so the kernel picks and the supervisor -- which holds the only listening socket
// -- tells every worker which port that was. Nothing here may name a port, two of these running at
// once being ordinary.
// **`object | null` and not `object`**, a spawn that failed being answered as nothing here: slate
// 0.0.41 checks a `return` against the annotation, so the narrower one would fault with a sentence
// about the result type in place of the one about the spawn.
async started(name: string, workers: integer) -> object | null
    val where = ".cluster-" + name

    await swept(where)
    await mkdir(where)

    val out = spawn("slate", ["tests-cluster/board.sl"],
        { env: { PATH: env("PATH") ?? "", HOME: env("HOME") ?? "", BOARD_CLUSTER_DIR: where,
                 BOARD_WORKERS: string(workers), PORT: "0",
                 BOARD_SECRET: "a key this suite made up" } })

    if !out.ok then return null

    val child = out.value

    if await grew(where, "ready", workers)
        val ready = await lines(where, "ready")

        return { child: child, where: where, port: number(split(ready[0], " ")[1]) }

    // **The program either never loaded or never served, and they are different answers.** A slate
    // without `slate:cluster` refuses the import at the top of `tests-cluster/board.sl` and nothing in
    // it runs, so the marker it writes before starting anything is missing -- that is a skip. A
    // marker with no workers behind it is a board that broke, and that is a failure.
    val loaded = await exists(where + "/loaded")

    await stopped({ child: child, where: where })

    if loaded then throw "the cluster started and never served" else null

async stopped(it: object)
    it.child.kill()

    await within(10000, it.child.exited, "the supervisor did not stop when it was asked to")

    await swept(it.where)

// -- reading what the workers wrote ---------------------------------------------------------------

async lines(where: string, name: string) -> array
    if !(await exists(where + "/" + name)) then return []

    val got = await readFile(where + "/" + name)

    if !got.ok then return []

    val out = []

    for line in split(got.value, "\n")
        if line != "" then push(out, line)

    out

// Wait until a file has `many` lines in it, or say it never did.
//
// **Its budget is shorter than the watchdog on purpose.** A line that never arrives is a claim that
// failed, and what a reader wants to be told is which claim -- so this answers `false` in time for the
// assertion that called it to say so, rather than being cut off by the alarm's sentence about time.
async grew(where: string, name: string, many: integer) -> boolean
    var waited = 0

    while waited < 15000
        if (await lines(where, name)).length >= many then return true

        await sleep(50)

        waited = waited + 50

    false

firsts(said: array) -> array
    val out = []

    for line in said
        push(out, split(line, " ")[0])

    out

distinct(said: array) -> array
    val out = []

    for one in said
        if !holds(out, one) then push(out, one)

    out

holds(xs: array, x) -> boolean
    for one in xs
        if one == x then return true

    false

biggest(said: array) -> integer
    var most = 0

    for one in said
        val n = number(one)

        if n is integer && n > most then most = n

    most

// -- the machine ----------------------------------------------------------------------------------

// **`slate:process`'s `run` is not on every back end, and a program has no name for which host it is
// running on** -- so, exactly as `tests/postgres.sl` asks by trying whether a socket can be bound,
// this asks by trying whether a child can be run at all.
async canRun() -> boolean
    try
        await run("true", [], {})
    catch e
        return false

    true

// The pids of a supervisor's workers, which is the only way to kill one and the only way to say
// afterwards that none of them is still running.
async children(pid: integer) -> array
    val got = await run("pgrep", ["-P", string(pid)], {})
    val out = []

    if !got.ok then return out

    for line in split(got.value.out, "\n")
        if line != "" then push(out, line)

    out

async alive(pid: string) -> boolean
    val got = await run("kill", ["-0", pid], {})

    got.ok && got.value.status == 0

// -- one request over a real socket -----------------------------------------------------------------

// **`Connection: close` is what makes a client five lines**: the answer ends when the socket does, so
// nothing here has to read a length or a chunked body. A connection that is refused answers a status
// of `0`, which is what a drained board looks like from outside.
async asked(port: integer, where: string) -> object
    val got = await connect("127.0.0.1", port)

    if !got.ok then return { status: 0, body: "" }

    val sock = got.value
    val whole = pending()

    var said = ""
    var done = false

    taking(chunk)
        if chunk == null
            done = true

            close(sock)
            settle(whole, said)
        else
            said = said + chunk

    trouble(e)
        if !done
            done = true

            settle(whole, said)

    onData(sock, taking)
    onError(sock, trouble)

    val sent = await send(sock, "GET " + where + " HTTP/1.1\r\nHost: 127.0.0.1\r\n" +
        "Connection: close\r\n\r\n")

    if !sent.ok then return { status: 0, body: "" }

    val text = await whole

    { status: statusOf(text), body: bodyOf(text) }

statusOf(text: string) -> integer
    val head = split(text, "\r\n")[0]
    val bits = split(head, " ")
    val n = if bits.length < 2 then null else number(bits[1])

    if n is integer then n else 0

bodyOf(text: string) -> string
    val at = indexOf(text, "\r\n\r\n")

    if at < 0 then "" else text[(at + 4)..]

// -- a watchdog, and a directory to leave behind nothing -------------------------------------------

// **Armed and cleared in the body.** A timer still armed when a test ends is a timer the runner's
// drain waits out, so the alarm is put out the moment the race is decided however it was decided.
async within(ms: integer, work, why: string)
    val alarm = pending()
    val id = setTimeout(() -> fail(alarm, why), ms)

    var trouble = null
    var got = null

    // **The alarm is put out on the way past a failure as well as on the way past a success**, or a
    // test that fails an assertion in a millisecond takes the whole watchdog to say so: the fault
    // travels straight out of the race, the timer is left armed behind it, and the runner's drain
    // waits it out. Measured at 30 seconds a failure before this `try` was here.
    try
        got = await race([work, alarm])
    catch e
        trouble = e

    clearTimeout(id)

    if trouble != null then throw trouble

    got

async swept(where: string)
    if !(await exists(where)) then return

    val got = await readDir(where)

    if got.ok
        for name in got.value
            await remove(where + "/" + name)

    await rmdir(where)
