#!/usr/bin/env slate
// The schema, applied.
//
//     scripts/migrate.sl
//     PG_URL=postgres://user:secret@host/board scripts/migrate.sl
//
// **`schema.sql` is read and run rather than held in a string beside the queries**, which is what puts
// a schema somewhere a review can see it. Every statement in it is `if not exists`, so running this
// twice does what running it once did.
//
// **No parameters, so it goes as a simple `Query`** -- which is the only protocol message that may
// carry several statements, and a schema is several statements.

import { pg } from pg
import { readFile } from slate:fs
import { exit } from slate:process

import { configuration } from "../api/postgres.sl"

val Schema = "./schema.sql"

async main()
    val text = await readFile(Schema)

    if !text.ok
        print("cannot read " + Schema + ":", text.error)
        print("run this from the repository's own directory")

        exit(1)

    val made = await pg(configuration())

    if !made.ok
        print("no database:", made.error)
        print("say where one is: PG_URL=postgres://user:secret@host/board")

        exit(1)

    val db = made.value
    val done = await db.query(text.value)

    db.close()

    if !done.ok
        print("the schema was refused:", done.error)

        exit(1)

    print("the board's schema is in place")

main()
