// The parts of `db.sl` that touch no cluster: which subcommand was asked for, which port a run
// resolves to, and the address the user is told to export.
//
// **Split out of `db.sl` so a test can import it.** `db.sl` ends with an unconditional `main()`,
// exactly as `migrate.sl` and `build.sl` do -- so importing it would start a server. Nothing here
// opens a socket or runs a child process.

val Commands = ["start", "stop", "status", "reset"]

export val DefaultPort = 5432

export usage() = "usage: slate scripts/db.sl [start|stop|status|reset]"

// The subcommand `args` asked for, defaulting to `start`, or `null` where the word is not one of
// the four this script knows.
export commandFrom(args: array of string) -> string | null
    // **Indexing an empty array faults rather than answering `undefined`**, so the length is asked
    // first -- `args[0] ?? "start"` looks right and dies on no arguments at all.
    val asked = if args.length == 0 then "start" else args[0]

    if contains(Commands, asked) then asked else null

// `PG_PORT`'s text turned into the port to use, or the default where it is absent or not a port.
export portOf(said: string) -> integer
    val n = number(said)

    if n is integer && n > 0 then n else DefaultPort

// The address to export -- `postgres://user@127.0.0.1/board` at the default port, since that is
// where `pg`'s own defaults already look, and `:port` only where a `PG_PORT` moved it.
export urlFor(user: string, port: integer) -> string
    val suffix = if port == DefaultPort then "" else ":" + string(port)

    "postgres://" + user + "@127.0.0.1" + suffix + "/board"
