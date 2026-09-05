// The browser half, built.
//
//     slate scripts/build.sl
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

import { run } from slate:process
import { exit } from slate:process

async main()
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
