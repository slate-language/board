// `api/postgres.sl` against a PostgreSQL server written in slate.
//
// **This is the half `tests/routes.sl` cannot reach.** That file substitutes a store over ordinary
// arrays, which says everything about the routes and nothing about the SQL; this one runs the real
// store over a real socket and reads what it actually sent -- the statements, the parameters, the
// SQLSTATE a unique violation comes back as, and the columns as the types they were read into.
//
// **A HOST MAY NOT HAVE EVERYTHING THIS FILE NEEDS, AND EACH TEST ASKS BY TRYING** -- a slate program
// having no name for which host it is running on. There are two such questions: whether a socket can
// be bound at all, and whether `slate:password` can hash. A name that is not on a back end imports
// fine and says *"not in the JavaScript back end yet"* when a program reaches it, so the probe is the
// call itself. `skip(reason)` is what a test that cannot run says; before that name existed it could
// only `return`, which is a pass nobody is ever told about.

import { close as closeSocket } from slate:net
import { hash } from slate:password

import { orderNamed, postgres } from "../api/postgres.sl"
import { server, portOf } from "./pgserver.sl"

// **A test that hangs is worse than a test that fails**, a socket keeping the program alive and the
// runner waiting out the rest of the run with nothing printed.
val Guard = 5000

val ThreadColumns = [{ name: "id", oid: 23 }, { name: "title", oid: 25 }, { name: "body", oid: 25 },
                     { name: "photo", oid: 25 }, { name: "replies", oid: 23 },
                     { name: "author", oid: 23 }, { name: "author_name", oid: 25 },
                     { name: "author_avatar", oid: 25 }, { name: "made", oid: 20 },
                     { name: "active", oid: 20 }]

val UserColumns = [{ name: "id", oid: 23 }, { name: "name", oid: 25 }, { name: "role", oid: 25 },
                   { name: "avatar", oid: 25 }, { name: "made", oid: 20 }]

var probed = null

// Whether this host has sockets at all, asked once by trying.
sockets() -> boolean
    if probed == null then probed = askedFor()

    probed

askedFor() -> boolean
    val s = server((sql, params) -> { tag: "SELECT 0" }) catch e -> null

    if s == null then return false

    closeSocket(s)

    true

var hashing = null

// Whether this host can hash a password, asked once and the same way.
//
// **`slate:password` is not on the JavaScript back end**, where `hash` says *"not in the JavaScript
// back end yet"* when a program reaches it -- so the three tests that need a real Argon2id record ask
// by trying, exactly as the socket probe does. The other statements this file checks need no hash and
// run on both hosts.
async passwords() -> boolean
    if hashing == null then hashing = await triedHash()

    hashing

async triedHash() -> boolean
    try
        await hash("a probe and not a password")
    catch e
        return false

    true

late(what: string) = setTimeout(() -> ranLong(what), Guard)

ranLong(what: string)
    throw "the " + what + " did not finish in time"

// A server whose answers are canned, keeping every statement it was sent.
told(replies: object, seen: array) -> function
    replying(sql, params)
        push(seen, { sql: sql, params: params })

        for [prefix, said] in entries(replies)
            if contains(sql, prefix) then return said

        { tag: "SELECT 0" }

    replying

async opened(replies: object, seen: array) -> object
    val fake = server(told(replies, seen))
    val made = await postgres({ host: "127.0.0.1",
                                port: portOf(fake),
                                user: "ada",
                                password: "pencil",
                                database: "board" })

    { fake: fake, made: made }

shut(open: object)
    if open.made.ok then open.made.value.close()

    closeSocket(open.fake)

// A board with one thread and one person in it.
val OneThread = { "select count(*) as n": { fields: [{ name: "n", oid: 20 }], rows: [["1"]],
                                            tag: "SELECT 1" },
                  "select t.id, t.title": { fields: ThreadColumns,
                                            rows: [["1", "Hello", "a body", null, "2", "1", "ada",
                                                    null, "1756900100", "1756900300"]],
                                            tag: "SELECT 1" },
                  "select thread, tag from tags": { fields: [{ name: "thread", oid: 23 },
                                                             { name: "tag", oid: 25 }],
                                                    rows: [["1", "slate"], ["1", "sluice"]],
                                                    tag: "SELECT 2" },
                  "select 1 as up": { fields: [{ name: "up", oid: 23 }], rows: [["1"]],
                                      tag: "SELECT 1" } }

// -- what the list sends -------------------------------------------------------------------------------

@test
async THE_LIST_ASKS_FOR_A_COUNT_AND_THEN_A_PAGE()
    if !sockets() then skip("this host has no listener, so there is no server to speak to")

    val guard = late("list test")
    val seen = []
    val open = await opened(OneThread, seen)

    assert(open.made.ok)

    val got = await open.made.value.threads({ sort: "newest", tag: "", q: "", page: 1, size: 20 })

    assert(got.ok)
    assertEq(got.value.total, 1)
    assertEq(got.value.rows[0].title, "Hello")

    // **The tags of a page of threads come back in one round trip and not one per row.**
    assertEq(got.value.rows[0].tags, ["slate", "sluice"])

    // **`made` is epoch SECONDS and comes back an integer**, which is what `extract(epoch …)::bigint`
    // is for: a page renders it, and an integer is a value every JSON encoder and both back ends agree
    // about.
    assertEq(got.value.rows[0].made, 1756900100)

    assertEq(len(seen), 3)
    assert(contains(seen[0].sql, "select count(*) as n from threads t"))
    assert(contains(seen[1].sql, "limit 20 offset 0"))

    clearTimeout(guard)
    shut(open)

@test
async A_TAG_AND_A_SEARCH_TRAVEL_AS_PARAMETERS_AND_NEVER_AS_TEXT()
    if !sockets() then skip("this host has no listener, so there is no server to speak to")

    val guard = late("filter test")
    val seen = []
    val open = await opened(OneThread, seen)

    await open.made.value.threads({ sort: "busiest", tag: "slate", q: "100%", page: 2, size: 5 })

    // **The server parses the statement before it is given a single value**, so nothing a person typed
    // can become part of the query -- `$1` is the whole of the defence and there is nothing to escape.
    assert(contains(seen[0].sql, "g.tag = $1"))
    assert(contains(seen[0].sql, "t.title ilike $2"))
    assertEq(seen[0].params[0], "slate")

    // **`%` and `_` are `like`'s own wildcards**, so a search for `100%` is escaped or it matches
    // everything beginning `100`.
    assertEq(seen[0].params[1], "%100\\%%")

    // The order is a constant chosen by a name, and the page is arithmetic on integers.
    assert(contains(seen[1].sql, "order by t.replies desc, t.made desc, t.id desc"))
    assert(contains(seen[1].sql, "limit 5 offset 5"))

    clearTimeout(guard)
    shut(open)

@test
A_SORT_KEY_A_CLIENT_INVENTED_IS_THE_FIRST_ONE()
    // **A sort key is the one part of a query that cannot be a parameter**, so this is the one place
    // the application has to hold the list itself -- and it needs no socket to check.
    assertEq(orderNamed("busiest"), "t.replies desc, t.made desc, t.id desc")
    assertEq(orderNamed("newest"), "t.made desc, t.id desc")
    assertEq(orderNamed("; drop table threads"), "t.made desc, t.id desc")
    assertEq(orderNamed(null), "t.made desc, t.id desc")

// -- people ---------------------------------------------------------------------------------------------

@test
async A_PASSWORD_IS_HASHED_ON_THE_WAY_IN_AND_NEVER_COMES_BACK_OUT()
    if !sockets() then skip("this host has no listener, so there is no server to speak to")
    if !(await passwords()) then skip("slate:password is not on this back end, so there is no hash to check")

    val guard = late("sign-up test")
    val seen = []
    val open = await opened({ "insert into users": { fields: UserColumns,
                                                     rows: [["3", "hopper", "member", null,
                                                             "1756900000"]],
                                                     tag: "INSERT 0 1" } }, seen)
    val made = await open.made.value.signUp("hopper", "correct horse", "member")

    assert(made.ok)
    assertEq(made.value.name, "hopper")
    assertEq(has(made.value, "password"), false)

    // **What went to the database is an Argon2id PHC record and not the password.**
    assertEq(seen[0].params[0], "hopper")
    assert(startsWith(seen[0].params[1], "$argon2id$"))
    assert(!contains(seen[0].params[1], "correct horse"))

    clearTimeout(guard)
    shut(open)

@test
async A_NAME_SOMEBODY_ELSE_HAS_COMES_BACK_AS_23505_AND_NOT_AS_A_FAULT()
    if !sockets() then skip("this host has no listener, so there is no server to speak to")
    if !(await passwords()) then skip("slate:password is not on this back end, and signing up hashes")

    val guard = late("duplicate test")
    val seen = []
    val open = await opened({ "insert into users": { error: { code: "23505",
                                                              message: "duplicate key value" } } }, seen)
    val made = await open.made.value.signUp("ada", "correct horse", "member")

    // **A unique index refusing a row is one round trip**, where a `select` first would be a race
    // between two people picking the same name -- and the SQLSTATE survives the trip, which is the
    // whole of what this layer owes the one above it.
    assert(!made.ok)
    assertEq(made.code, "23505")

    clearTimeout(guard)
    shut(open)

@test
async A_PASSWORD_IS_CHECKED_AGAINST_THE_RECORD_AND_A_WRONG_ONE_IS_A_NULL()
    if !sockets() then skip("this host has no listener, so there is no server to speak to")
    if !(await passwords()) then skip("slate:password is not on this back end, so there is nothing to check against")

    val guard = late("sign-in test")
    val seen = []
    val stored = await hash("correct horse")
    val open = await opened({ "select id, name, role, avatar, password":
        { fields: [{ name: "id", oid: 23 }, { name: "name", oid: 25 }, { name: "role", oid: 25 },
                   { name: "avatar", oid: 25 }, { name: "password", oid: 25 },
                   { name: "made", oid: 20 }],
          rows: [["1", "ada", "admin", null, stored, "1756900000"]],
          tag: "SELECT 1" } }, seen)
    val store = open.made.value
    val right = await store.signIn("ada", "correct horse")
    val wrong = await store.signIn("ada", "not it")

    assert(right.ok)
    assertEq(right.value.name, "ada")

    // **A password column never leaves that file**, which is the rule this asserts from outside.
    assertEq(has(right.value, "password"), false)

    // **A wrong password is a null and not a failure**: there is nobody signed in, which is a thing a
    // handler deals with rather than a defect in the program.
    assert(wrong.ok)
    assertEq(wrong.value, null)

    clearTimeout(guard)
    shut(open)

// -- replies ----------------------------------------------------------------------------------------------

@test
async A_REPLY_AND_THE_THREAD_S_COUNTERS_MOVE_IN_ONE_TRANSACTION()
    if !sockets() then skip("this host has no listener, so there is no server to speak to")

    val guard = late("reply test")
    val seen = []
    val open = await opened({ "insert into replies": { fields: [{ name: "id", oid: 23 }],
                                                       rows: [["9"]], tag: "INSERT 0 1" },
                              "select r.id, r.thread": { fields: [{ name: "id", oid: 23 },
                                                                  { name: "thread", oid: 23 },
                                                                  { name: "body", oid: 25 },
                                                                  { name: "photo", oid: 25 },
                                                                  { name: "author", oid: 23 },
                                                                  { name: "author_name", oid: 25 },
                                                                  { name: "author_avatar", oid: 25 },
                                                                  { name: "made", oid: 20 }],
                                                         rows: [["9", "1", "hello", null, "2",
                                                                 "grace", null, "1756900400"]],
                                                         tag: "SELECT 1" } }, seen)
    val made = await open.made.value.addReply({ thread: 1, body: "hello", author: 2, photo: null })

    assert(made.ok)
    assertEq(made.value.id, 9)

    // **A reader never sees a reply the list says is not there.** `begin` and `commit` are SQL because
    // they already are.
    assertEq(trim(seen[0].sql), "begin")
    assert(contains(seen[1].sql, "insert into replies"))
    assert(contains(seen[2].sql, "replies = replies + 1"))
    assert(contains(seen[2].sql, "active = now()"))
    assertEq(trim(seen[3].sql), "commit")

    clearTimeout(guard)
    shut(open)

// -- staying up ---------------------------------------------------------------------------------------------

@test
async THE_HEALTH_CHECK_IS_A_ROUND_TRIP_AND_NOT_A_FLAG()
    if !sockets() then skip("this host has no listener, so there is no server to speak to")

    val guard = late("health test")
    val seen = []
    val open = await opened(OneThread, seen)
    val well = await open.made.value.ping()

    assert(well.ok)
    assert(contains(seen[0].sql, "select 1 as up"))

    clearTimeout(guard)
    shut(open)

@test
async A_DATABASE_THAT_IS_NOT_THERE_IS_AN_ANSWER_AND_NOT_A_FAULT()
    if !sockets() then skip("this host has no listener, so there is no server to speak to")

    val guard = late("no-database test")

    // Port 1 is not something anybody is listening on, and a connection that cannot be made is a
    // condition every program handles rather than a defect in it.
    val made = await postgres({ host: "127.0.0.1", port: 1, user: "ada", database: "board" })

    assert(!made.ok)
    assert(made.error != "")

    clearTimeout(guard)
