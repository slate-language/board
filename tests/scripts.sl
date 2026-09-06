// `scripts/db.sl`'s pure parts, and the one thing worth proving about the whole program without a
// cluster: that an unknown subcommand refuses rather than defaulting to `start`.
//
// **The pure parts live in `scripts/dbLogic.sl` and not in `db.sl` itself.** `db.sl` ends with an
// unconditional `main()`, exactly as `migrate.sl` and `build.sl` do, so importing it here would try
// to start a server the moment this file loaded.

import { env, run } from slate:process

import { DefaultPort, commandFrom, portOf, urlFor } from "../scripts/dbLogic.sl"
import { configuration } from "../api/postgres.sl"

// **`slate:process`'s `run` is not on the JavaScript back end yet, and a program has no name for
// which host it is running on** -- so, exactly as `tests/postgres.sl` asks by trying whether a
// socket can be bound, this asks by trying whether a child can be spawned at all.
async canRun() -> boolean
    try
        await run("true", [], {})
    catch e
        return false

    true

@test
A_MISSING_SUBCOMMAND_IS_start()
    assertEq(commandFrom([]), "start")

@test
AN_UNKNOWN_SUBCOMMAND_IS_NOT_ONE_OF_THE_FOUR()
    assertEq(commandFrom(["bogus"]), null)

@test
EVERY_KNOWN_SUBCOMMAND_PASSES_THROUGH()
    assertEq(commandFrom(["start"]), "start")
    assertEq(commandFrom(["stop"]), "stop")
    assertEq(commandFrom(["status"]), "status")
    assertEq(commandFrom(["reset"]), "reset")

@test
PG_PORT_S_TEXT_BECOMES_THE_PORT()
    assertEq(portOf("55433"), 55433)

@test
A_PORT_THAT_IS_NOT_A_NUMBER_IS_THE_DEFAULT()
    assertEq(portOf(""), DefaultPort)
    assertEq(portOf("not a port"), DefaultPort)
    assertEq(portOf("0"), DefaultPort)
    assertEq(portOf("-1"), DefaultPort)

@test
THE_DEFAULT_PORT_NEEDS_NO_SUFFIX_ON_THE_ADDRESS()
    assertEq(urlFor("ed", DefaultPort), "postgres://ed@127.0.0.1/board")

@test
A_MOVED_PORT_IS_PART_OF_THE_ADDRESS()
    assertEq(urlFor("ed", 55433), "postgres://ed@127.0.0.1:55433/board")

@test
async AN_UNKNOWN_SUBCOMMAND_EXITS_1_WITH_A_USAGE_LINE()
    if !(await canRun()) then skip("waiting on `run` on this host: there is no child process without one")

    val said = await run("slate", ["scripts/db.sl", "bogus"], {})

    assert(said.ok)
    assertEq(said.value.status, 1)
    assert(contains(said.value.out, "usage:"))

@test
WITH_NOTHING_SET_THE_BOARD_OPENS_A_DATABASE_NAMED_BOARD()
    // **`psql` with nothing set opens a database named after the user; this program opens `board`**,
    // which is the one `scripts/db.sl` makes. Everything else -- host, port, user -- is still left to
    // `pg`'s own reading of the environment, so only the database is named here.
    val got = configuration()

    assert(got is object)
    assertEq(got.database, env("PGDATABASE") ?? "board")
