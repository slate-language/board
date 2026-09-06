// `api/postgres.sl` against a PostgreSQL server written in slate.
//
// **This is the half `tests/routes.sl` cannot reach.** That file substitutes a store over ordinary
// arrays, which says everything about the routes and nothing about the SQL; this one runs the real
// store over a real socket and reads what it actually sent -- the statements, the parameters, the
// SQLSTATE a unique violation comes back as, and the columns as the types they were read into.
//
// **A HOST MAY NOT HAVE EVERYTHING THIS FILE NEEDS, AND EACH TEST ASKS BY TRYING** -- a slate program
// having no name for which host it is running on. There are two such questions: whether a socket can
// be bound at all, and whether `argon2` can hash. A name that is not on a back end imports
// fine and says *"not in the JavaScript back end yet"* when a program reaches it, so the probe is the
// call itself. `skip(reason)` is what a test that cannot run says; before that name existed it could
// only `return`, which is a pass nobody is ever told about.

import { close as closeSocket } from slate:net
import { argon2, argon2NeedsRehash, argon2Verify } from slate:crypto

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

// The columns a sign-in reads, which is the one query that comes back with a password on it.
val SignInColumns = [{ name: "id", oid: 23 }, { name: "name", oid: 25 }, { name: "role", oid: 25 },
                     { name: "avatar", oid: 25 }, { name: "password", oid: 25 },
                     { name: "made", oid: 20 }]

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
// **`argon2` is Argon2id and a host may simply not have it**, saying so when a program reaches it --
// so the three tests that need a real Argon2id record ask by trying, exactly as the socket probe
// does. The other statements this file checks need no hash and run on both hosts.
async passwords() -> boolean
    if hashing == null then hashing = await triedHash()

    hashing

async triedHash() -> boolean
    try
        await argon2("a probe and not a password")
    catch e
        return false

    true

// -- what stands around every test in this file ----------------------------------------------------------
//
// **THE HOOKS OWN THE STATE AND THE BODY STILL OWNS THE LOOP**, which is not the split anybody would
// choose and is the one slate 0.0.32 allows. **A HOOK IS OUTSIDE THE RUNNER'S PER-TEST DRAIN**, and
// both halves of that bite:
//
// - a `@setup` that leaves a live handle -- a listener, an armed timer -- stops the loop delivering
//   anything to the test after it, and the run hangs with nothing printed at all;
// - a `@teardown` runs AFTER the drain, so it cannot put out a timer or close a socket the body left:
//   the drain waits the timer out first, and a three-second watchdog cleared in a teardown fails the
//   test three seconds later instead of passing at once.
//
// So `talking` opens and `shut` closes, both from the body, and the `@teardown` beside them is the
// second line of defence rather than the first -- it does run once the watchdog has ended a hang, and
// what it gives back then is a socket the body never reached.
//
// **What a test says back is `replies` and what it reads is `seen`**, both put back by `@setup`; the
// server reads them where it stands, there being nothing else to hand a hook. So a test is one line
// of canned answers, the call it makes, what it asserts about the statements, and `shut()`.

// What the server says back, and every statement it was sent.
var replies = {}
var seen = []

// The listening socket, the client speaking to it, and the watchdog.
var fake = null
var store = null
var guard = null

// A server whose answers are canned, keeping every statement it was sent.
replying(sql, params)
    push(seen, { sql: sql, params: params })

    for [prefix, said] in entries(replies)
        if contains(sql, prefix) then return said

    { tag: "SELECT 0" }

// The bell that ends a hang, armed by every test that opens a socket and put out by `shut`.
watched()
    guard = setTimeout(ranLong, Guard)

ranLong()
    throw "a test in this file did not finish in time"

// `talking(said)` -- a server answering out of `said`, and a store speaking to it.
async talking(said: object)
    watched()

    replies = said
    fake = server(replying)

    val made = await postgres({ host: "127.0.0.1",
                                port: portOf(fake),
                                user: "ada",
                                password: "pencil",
                                database: "board" })

    if !made.ok then throw "the test server would not take a connection: " + made.error

    store = made.value

    // **The count starts AFTER the connection and not before it**, so that a startup exchange which
    // ever did send a statement would be counted where it belongs rather than in the test's own.
    seen = []

    null

// Everything `talking` and `watched` took, given back. **The last line of a test that opened
// anything**, for the reason at the head of this section.
shut()
    if guard != null then clearTimeout(guard)
    if store != null then store.close()
    if fake != null then closeSocket(fake)

    guard = null
    store = null
    fake = null

@setup
freshServer()
    replies = {}
    seen = []
    fake = null
    store = null
    guard = null

@teardown
disconnect()
    shut()

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
    if !sockets() then skip("waiting on a listener on this host: there is no server to speak to without one")

    await talking(OneThread)

    val got = await store.threads({ sort: "newest", tag: "", q: "", page: 1, size: 20 })

    assert(got.ok)
    assertEq(got.value.total, 1)
    assertEq(got.value.rows[0].title, "Hello")

    // **The tags of a page of threads come back in one round trip and not one per row.**
    assertEq(got.value.rows[0].tags, ["slate", "sluice"])

    // **`made` is epoch SECONDS and comes back an integer**, which is what `extract(epoch …)::bigint`
    // is for: a page renders it, and an integer is a value every JSON encoder and both back ends agree
    // about.
    assertEq(got.value.rows[0].made, 1756900100)

    assertEq(seen.length, 3)
    assert(contains(seen[0].sql, "select count(*) as n from threads t"))
    assert(contains(seen[1].sql, "limit 20 offset 0"))

    shut()

@test
async A_TAG_AND_A_SEARCH_TRAVEL_AS_PARAMETERS_AND_NEVER_AS_TEXT()
    if !sockets() then skip("waiting on a listener on this host: there is no server to speak to without one")

    await talking(OneThread)

    await store.threads({ sort: "busiest", tag: "slate", q: "100%", page: 2, size: 5 })

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

    shut()

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
    if !sockets() then skip("waiting on a listener on this host: there is no server to speak to without one")
    if !(await passwords()) then skip("waiting on `argon2` on this back end: there is no hash to check without it")

    await talking({ "insert into users": { fields: UserColumns,
                                           rows: [["3", "hopper", "member", null, "1756900000"]],
                                           tag: "INSERT 0 1" } })

    val made = await store.signUp("hopper", "correct horse", "member")

    assert(made.ok)
    assertEq(made.value.name, "hopper")
    assertEq(has(made.value, "password"), false)

    // **What went to the database is an Argon2id PHC record and not the password.**
    assertEq(seen[0].params[0], "hopper")
    assert(startsWith(seen[0].params[1], "$argon2id$"))
    assert(!contains(seen[0].params[1], "correct horse"))

    shut()

@test
async A_NAME_SOMEBODY_ELSE_HAS_COMES_BACK_AS_23505_AND_NOT_AS_A_FAULT()
    if !sockets() then skip("waiting on a listener on this host: there is no server to speak to without one")
    if !(await passwords()) then skip("waiting on `argon2` on this back end: signing up hashes")

    await talking({ "insert into users": { error: { code: "23505",
                                                    message: "duplicate key value" } } })

    val made = await store.signUp("ada", "correct horse", "member")

    // **A unique index refusing a row is one round trip**, where a `select` first would be a race
    // between two people picking the same name -- and the SQLSTATE survives the trip, which is the
    // whole of what this layer owes the one above it.
    assert(!made.ok)
    assertEq(made.code, "23505")

    shut()

@test
async A_PASSWORD_IS_CHECKED_AGAINST_THE_RECORD_AND_A_WRONG_ONE_IS_A_NULL()
    if !sockets() then skip("waiting on a listener on this host: there is no server to speak to without one")
    if !(await passwords()) then skip("waiting on `argon2` on this back end: there is nothing to check against without it")

    val kept = await argon2("correct horse")

    await talking({ "select id, name, role, avatar, password":
                        { fields: SignInColumns,
                          rows: [["1", "ada", "admin", null, kept, "1756900000"]],
                          tag: "SELECT 1" } })

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

    shut()

@test
async SIGNING_IN_REPLACES_A_RECORD_HASHED_UNDER_WEAKER_PARAMETERS()
    if !sockets() then skip("waiting on a listener on this host: there is no server to speak to without one")
    if !(await passwords()) then skip("waiting on `argon2` on this back end: there is nothing to re-hash without it")

    // **A record from a board whose numbers were smaller**, which is what the parameters travelling
    // inside a record make possible: it still verifies, and it is still below what is written today.
    val old = await argon2("correct horse", { memoryCost: 8192, timeCost: 1 })

    assert(contains(old, "m=8192,t=1"))
    assert(await argon2Verify(old, "correct horse"))
    assert(argon2NeedsRehash(old))

    await talking({ "select id, name, role, avatar, password":
                        { fields: SignInColumns,
                          rows: [["1", "ada", "admin", null, old, "1756900000"]],
                          tag: "SELECT 1" },
                    "update users set password": { tag: "UPDATE 1" } })

    val who = await store.signIn("ada", "correct horse")

    // **The sign-in is a sign-in and the upgrade is beside it**, so what the caller gets back is what
    // it would have got anyway.
    assert(who.ok)
    assertEq(who.value.name, "ada")
    assertEq(has(who.value, "password"), false)

    // **The one moment the plaintext is in hand is the moment after a successful verify**, so the
    // second statement of a sign-in is the update that stores the stronger record.
    assertEq(seen.length, 2)
    assert(contains(seen[1].sql, "update users set password"))
    assert(startsWith(seen[1].params[0], "$argon2id$v=19$m=19456,t=2"))
    assertEq(string(seen[1].params[1]), "1")
    assertEq(argon2NeedsRehash(seen[1].params[0]), false)
    assert(await argon2Verify(seen[1].params[0], "correct horse"))

    shut()

@test
async A_RECORD_ALREADY_AT_TODAY_S_NUMBERS_IS_LEFT_ALONE()
    if !sockets() then skip("waiting on a listener on this host: there is no server to speak to without one")
    if !(await passwords()) then skip("waiting on `argon2` on this back end: there is no record to leave alone without it")

    val current = await argon2("correct horse")

    await talking({ "select id, name, role, avatar, password":
                        { fields: SignInColumns,
                          rows: [["1", "ada", "admin", null, current, "1756900000"]],
                          tag: "SELECT 1" } })

    val who = await store.signIn("ada", "correct horse")

    assert(who.ok)

    // **One statement and no write**, which is what every sign-in after the first upgrade costs.
    assertEq(seen.length, 1)

    shut()

@test
async A_PASSWORD_COLUMN_THAT_IS_NOT_AN_ARGON2_RECORD_IS_A_FAULT()
    if !sockets() then skip("waiting on a listener on this host: there is no server to speak to without one")
    if !(await passwords()) then skip("waiting on `argon2` on this back end: a bad record faults for the wrong reason without it")

    await talking({ "select id, name, role, avatar, password":
                        { fields: SignInColumns,
                          rows: [["1", "ada", "admin", null, "a plaintext password", "1756900000"]],
                          tag: "SELECT 1" } })

    // **A row that will not parse is a defect in whatever wrote the column and not somebody guessing**,
    // which is why `argon2Verify` faults over it rather than answering `false`: a corrupted row read as
    // a wrong password is the one confusion a sign-in must not have, and this store passes that
    // distinction straight up.
    await assertFaults(() -> store.signIn("ada", "correct horse"), "not an Argon2 record")

    shut()

// -- replies ----------------------------------------------------------------------------------------------

@test
async A_REPLY_AND_THE_THREAD_S_COUNTERS_MOVE_IN_ONE_TRANSACTION()
    if !sockets() then skip("waiting on a listener on this host: there is no server to speak to without one")

    await talking({ "insert into replies": { fields: [{ name: "id", oid: 23 }],
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
                                               tag: "SELECT 1" } })

    val made = await store.addReply({ thread: 1, body: "hello", author: 2, photo: null })

    assert(made.ok)
    assertEq(made.value.id, 9)

    // **A reader never sees a reply the list says is not there.** `begin` and `commit` are SQL because
    // they already are.
    assertEq(trim(seen[0].sql), "begin")
    assert(contains(seen[1].sql, "insert into replies"))
    assert(contains(seen[2].sql, "replies = replies + 1"))
    assert(contains(seen[2].sql, "active = now()"))
    assertEq(trim(seen[3].sql), "commit")

    shut()

// -- staying up ---------------------------------------------------------------------------------------------

@test
async THE_HEALTH_CHECK_IS_A_ROUND_TRIP_AND_NOT_A_FLAG()
    if !sockets() then skip("waiting on a listener on this host: there is no server to speak to without one")

    await talking(OneThread)

    val well = await store.ping()

    assert(well.ok)
    assert(contains(seen[0].sql, "select 1 as up"))

    shut()

@test
async A_DATABASE_THAT_IS_NOT_THERE_IS_AN_ANSWER_AND_NOT_A_FAULT()
    if !sockets() then skip("waiting on a listener on this host: there is no server to speak to without one")

    watched()

    // Port 1 is not something anybody is listening on, and a connection that cannot be made is a
    // condition every program handles rather than a defect in it.
    val made = await postgres({ host: "127.0.0.1", port: 1, user: "ada", database: "board" })

    assert(!made.ok)
    assert(made.error != "")

    shut()
