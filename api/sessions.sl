// The session store, and the one thing an admin page needs that a store does not have.
//
// **A store is three plain functions** -- `get(id)`, `set(id, value, ttl)`, `delete(id)`, each of which
// may answer a promise -- and `sluice`'s `memoryStore()` is one. This wraps one and keeps a register
// of who is signed in beside it, because **a handler is never told its own session's id**: the cookie
// carries a signed id, the guard reads it, and `req.session` is `{ value, set, destroy }`. So an
// application that wants to *revoke somebody else's* session -- which is the whole reason to have a
// store at all -- has nowhere to get an id from unless it watched them being written.
//
// **A store over PostgreSQL is the same three functions and would keep no register**, a table being
// something you can already select from:
//
//     { get: (id) -> one("select value from sessions where id = $1 and until > now()", id),
//       set: (id, value, ttl) -> upsert(id, value, ttl),
//       delete: (id) -> run("delete from sessions where id = $1", id) }
//
// Swapping it in is one line in `server.sl` and nothing else changes -- and on a fleet it is the swap
// that has to happen, a store in this process being a store one machine has.

import { memoryStore } from sluice
import { epochSeconds, now } from slate:time

// `sessionStore(options)` -- a `memoryStore` that also answers `live()` and `revoke(id)`.
//
// `options` are `memoryStore`'s: `ttl`, a default lifetime in milliseconds, and `now`, a clock -- which
// is what makes expiry testable without a sleep in a test.
export sessionStore(options: object = {}) -> object
    val inner = memoryStore(options)
    var known = {}

    async get(id: string) = await inner.get(id)

    // **A session that is written is written under a NEW id and the old one is deleted**, which is how
    // `sluice` closes session fixation -- so this sees both halves and the register follows along.
    async set(id: string, value, ttl)
        val r = await inner.set(id, value, ttl)

        known[id] = { id: id,
                      name: (if value == null then null else value.name) ?? "somebody",
                      at: epochSeconds(now()) }

        r

    async delete(id: string)
        forget(id)

        await inner.delete(id)

    // **slate has no way to remove a key from an object** -- `keys`, `values`, `entries` and `has` are
    // the whole surface -- so forgetting one is building the table again without it. At the size of a
    // register of signed-in people that is the whole of the story; `sluice`'s own `memoryStore`
    // amortises the same rebuild because it holds every session ever written.
    forget(id: string)
        var next = {}

        for [key, entry] in entries(known)
            if key != id then next[key] = entry

        known = next

    // Who is signed in, newest first.
    //
    // **It asks the store about every id it is holding**, which is what keeps the register honest: an
    // entry the store has expired is gone from the answer and gone from the register, so this is the
    // only thing that has to sweep and nothing needs a timer.
    async live() -> array
        var out = []

        for [id, entry] in entries(known)
            val held = await inner.get(id)

            if held == null then forget(id) else push(out, entry)

        sortedByTime(out)

    // Somebody else's session, ended. **This is the thing a signed cookie cannot do at all**, and it
    // is the whole argument for a store.
    async revoke(id: string) -> boolean
        val held = await inner.get(id)

        await delete(id)

        held != null

    { get: get, set: set, delete: delete, live: live, revoke: revoke }

// **A comparator answers whether the first value comes BEFORE the second**, which is a boolean and not
// the sign of a subtraction -- the shape every other language takes.
sortedByTime(xs: array) -> array
    val out = xs

    out.sort(newerFirst)

    out

newerFirst(a: object, b: object) -> boolean = a.at > b.at
