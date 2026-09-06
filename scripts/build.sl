#!/usr/bin/env slate
// The browser half, built.
//
//     scripts/build.sl
//
// which is one command wrapping one command:
//
//     slate js client.slx -o public/app.js
//
// **`slate js` writes ONE self-contained file** -- the runtime, `lath`, and this program -- so there is
// no bundler, no `node_modules` and nothing to install beside it. `public/app.js` is not in git for
// the same reason no build output is: it is made from `client.slx` in a second.
//
// **The page works without it.** Every form is a real form, every link is a real anchor, and the
// server renders the markup -- so a missing `app.js` costs the page its live replies and its
// reload-free posts and nothing else.

import { mkdir } from slate:fs
import { run } from slate:process
import { exit } from slate:process

async main()
    // **`public/` is made here because nothing in git puts it there any more.** It held the board's
    // stylesheet until the styling moved into the program: a sheet is a file the compiler reads and
    // `lath`'s string host writes into the markup, so the only thing left to serve is this program.
    val made = await mkdir("public")

    if !made.ok && !contains(made.error, "EEXIST")
        print("could not make public/:", made.error)

        exit(1)

    print("slate js client.slx -o public/app.js")

    val built = await run("slate", ["js", "client.slx", "-o", "public/app.js"], {})

    if !built.ok
        print("could not run slate:", built.error)

        exit(1)

    if built.value.out != "" then print(built.value.out)
    if built.value.err != "" then print(built.value.err)

    if built.value.status != 0
        print("slate js answered", built.value.status)

        exit(built.value.status)

    print("public/app.js is built")

main()
