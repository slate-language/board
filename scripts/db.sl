#!/usr/bin/env slate
// The board's own development PostgreSQL, so `slate server.sl` never again dies with "no database".
//
//     scripts/db.sl
//     scripts/db.sl stop
//     scripts/db.sl status
//     scripts/db.sl reset
//
// **Homebrew's `postgresql@16` belongs to another account on this machine, not to whoever runs this
// script** -- `brew services start postgresql@16` installs a launchd agent that reads a data
// directory it cannot open and exits `EX_CONFIG`. The binaries are usable regardless: this script
// drives `initdb`, `pg_ctl`, `createdb` and `pg_isready` directly, and never through `brew services`.
//
// **The cluster lives in `.pgdata/` under the repository and is this script's alone to manage.**
// `reset` throws the whole directory away with no question asked, this being a development database
// and not a place anything is kept.
//
// **Trust auth on localhost is the whole of the security model here.** `initdb --auth=trust` answers
// every connection from this machine with no password, which is wrong for anything that is not a
// developer's own laptop and is exactly right for a database nobody but this script starts.

import { args, env, exit, run } from slate:process
import { exists } from slate:fs

import { DefaultPort, commandFrom, portOf, urlFor, usage } from "./dbLogic.sl"

val DataDir = ".pgdata"
val Database = "board"

resolvedUser() -> string = env("USER") ?? "postgres"

resolvedPort() -> integer = portOf(env("PG_PORT") ?? string(DefaultPort))

failed(what: string, said: string)
    print(what, said)
    exit(1)

// **`run`'s `env` REPLACES the child's, so leaving it out of an options object is what inherits the
// caller's whole environment** -- which is what every call below wants, PATH included, except the
// one to `scripts/migrate.sl`, which needs `PG_URL` ADDED rather than merely kept.
//
// **A binary is asked for on PATH first, and only then at `PG_BIN`** -- the same order the README
// documents: usable off PATH, never through `brew services`. A binary found at neither names both
// places this looked.
async runBin(name: string, cmdArgs: array of string) -> object
    val onPath = await run(name, cmdArgs, {})

    if onPath.ok then return onPath

    val bin = env("PG_BIN")

    if bin == null
        return { ok: false, error: "'" + name + "' is not on PATH, and PG_BIN is not set: " + onPath.error }

    val there = bin + "/" + name
    val atBin = await run(there, cmdArgs, {})

    if atBin.ok then return atBin

    { ok: false, error: "'" + name + "' is not on PATH and not at '" + there + "': " + atBin.error }

// `pg_ctl -D .pgdata status` answers 0 for a running server and a non-zero status for anything else
// -- a stopped one, a directory that has never been `initdb`'d, one that cannot be opened.
async serverRunning() -> boolean
    val checked = await runBin("pg_ctl", ["-D", DataDir, "status"])

    checked.ok && checked.value.status == 0

async startCommand()
    val user = resolvedUser()
    val port = resolvedPort()

    if !(await exists(DataDir))
        print("initdb -D " + DataDir + " -U " + user + " --auth=trust --encoding=UTF8")

        val made = await runBin("initdb", ["-D", DataDir, "-U", user, "--auth=trust", "--encoding=UTF8"])

        if !made.ok then failed("could not run initdb:", made.error)
        if made.value.status != 0 then failed("initdb answered " + string(made.value.status) + ":", made.value.err)

    if !(await serverRunning())
        // **`-l` is load-bearing and not only for the log.** Without it the server inherits this
        // call's own stdout/stderr, and `run` waits for both pipes to reach end of file -- which a
        // long-lived server never does, so the call hangs forever with nothing printed. `-w` waits
        // for the ready check `pg_ctl` runs internally and `-s` quiets what it prints while doing it.
        val started = await runBin("pg_ctl", ["-D", DataDir, "-l", DataDir + "/log", "-o",
                                              "-p " + string(port) + " -k /tmp", "-w", "-s", "start"])

        if !started.ok then failed("could not run pg_ctl:", started.error)
        if started.value.status != 0
            failed("pg_ctl start answered " + string(started.value.status) + ":", started.value.err)

        val ready = await runBin("pg_isready", ["-h", "127.0.0.1", "-p", string(port)])

        if !ready.ok then failed("could not run pg_isready:", ready.error)
        if ready.value.status != 0
            failed("the server started but is not answering:", ready.value.out + ready.value.err)

    val createdDb = await runBin("createdb", ["-h", "127.0.0.1", "-p", string(port), Database])

    if !createdDb.ok then failed("could not run createdb:", createdDb.error)
    if createdDb.value.status != 0 && !contains(createdDb.value.err, "already exists")
        failed("createdb answered " + string(createdDb.value.status) + ":", createdDb.value.err)

    val url = urlFor(user, port)

    print("scripts/migrate.sl")

    val migrated = await run("slate", ["scripts/migrate.sl"],
                             { env: { PG_URL: url, PATH: env("PATH") ?? "", HOME: env("HOME") ?? "" } })

    if !migrated.ok then failed("could not run slate:", migrated.error)
    if migrated.value.out != "" then print(migrated.value.out)
    if migrated.value.err != "" then print(migrated.value.err)
    if migrated.value.status != 0 then failed("the schema could not be applied, slate answered",
                                              string(migrated.value.status))

    if port == DefaultPort
        print("PG_URL needs no export: the board opens 127.0.0.1:" + string(DefaultPort) + "/board on its own")
    else
        print("export PG_URL=" + url)

    print("slate server.sl")

async stopCommand()
    if !(await exists(DataDir))
        print("no cluster at " + DataDir)
        return

    if !(await serverRunning())
        print("not running")
        return

    val stopped = await runBin("pg_ctl", ["-D", DataDir, "-m", "fast", "stop"])

    if !stopped.ok then failed("could not run pg_ctl:", stopped.error)
    if stopped.value.status != 0
        failed("pg_ctl stop answered " + string(stopped.value.status) + ":", stopped.value.err)

    print("stopped")

async statusCommand()
    if !(await exists(DataDir))
        print(DataDir + " does not exist -- never started")
        return

    val port = resolvedPort()

    if await serverRunning()
        print("running on port " + string(port) + ", data in " + DataDir)
    else
        print("not running, data in " + DataDir)

async resetCommand()
    await stopCommand()

    print("rm -rf " + DataDir)

    val removed = await run("rm", ["-rf", DataDir], {})

    if !removed.ok then failed("could not remove " + DataDir + ":", removed.error)
    if removed.value.status != 0 then failed("rm answered", string(removed.value.status))

    await startCommand()

async main()
    val cmd = commandFrom(args)

    if cmd == null
        print(usage())
        exit(1)

    if cmd == "start"
        await startCommand()
    elif cmd == "stop"
        await stopCommand()
    elif cmd == "status"
        await statusCommand()
    else
        await resetCommand()

main()
