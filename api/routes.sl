// The board, as HTTP. **This file holds no SQL and knows no database.**
//
// What it is written against is a STORE -- a plain object of functions, each answering a result and
// each of which may answer a promise. `api/postgres.sl` is one over `pg` and is the only file that
// knows a statement; `tests/store.sl` writes another over ordinary arrays, which is how every route
// below is driven with no database, no socket and nothing to start.
//
// **Every GET here answers a page or the values that page was made from**, and the handler does not
// know which -- `api/render.sl` decides on the request. So the same route serves a browser with no
// JavaScript, a browser running the page's own program, and `curl`.

import { api, body, csrf, hub, json, lastEventId, logger, problem, rateLimit, requestId, session,
    sse, stack, timeout } from sluice
import { files, setCookie } from slate:http

import { answered, backTo, moved, themeOf, wantsJson, whoIs } from "./render.sl"
import { formCsrf, given, titleFor, withCookie } from "./forms.sl"
import { keep, kindOf, pick, stored } from "./uploads.sl"

// -- what a client may send ------------------------------------------------------------------------
//
// **The declaration IS the validator.** `given(Shape)` checks a form, a multipart body or a JSON one
// against it and answers a `400` problem carrying every reason it did not fit rather than the first.
// A `?` member is one a form may leave out.

type Credentials = { name: string, password: string }
type NewThread = { title: string, body: string, tags?: string, back?: string }
type NewReply = { body: string, back?: string }
type Nothing = { back?: string }

// -- what a handler may fail with --------------------------------------------------------------------
//
// **A closed set, so the mapping below is CHECKED**: add a variant and leave it unanswered and this
// file stops compiling. That refusal is the whole argument for returning failures rather than throwing
// them.

data Failure
    NoSuchThread(id)
    NoSuchPerson(name)
    NotSignedIn(what)
    NotAllowed(what)
    Taken(name)
    Unavailable(reason)

// Every failure this application can produce, and what each one is as HTTP.
//
// **The annotation is what makes this checked.** slate proves the match covers the whole of `Failure`
// before the program runs, so a variant added above with no answer here is a compile error rather than
// a request that falls through to a 500.
answer(f: Failure) = f match
    NoSuchThread(id) -> problem(404, "Not Found", "there is no thread " + string(id))
    NoSuchPerson(name) -> problem(404, "Not Found", "there is nobody called " + string(name))
    NotSignedIn(what) -> problem(401, "Unauthorized", "you have to be signed in to " + string(what))
    NotAllowed(what) -> problem(403, "Forbidden", "that is not yours to " + string(what))
    Taken(name) -> problem(409, "Conflict", "the name " + string(name) + " is taken")
    Unavailable(reason) -> problem(503, "Service Unavailable", "the board is not answering",
        { reason: string(reason) })

// -- the orders the list offers ----------------------------------------------------------------------

// **A sort key is the one part of a query that cannot be a parameter**, so the list of them lives in
// the program. Anything a client says that is not one of these is the first.
val Sorts = ["newest", "active", "busiest"]

// How long a photo may be kept. **A year and `immutable`**, which is what a content-addressed name
// earns: a browser that has the file never asks about it again, and a photo that changed would be a
// different address.
val Forever = "max-age=31536000, immutable"

sortOf(said) -> string
    val name = string(said ?? "")

    if contains(Sorts, name) then name else "newest"

// -- the application -----------------------------------------------------------------------------

// `application(store, sessions, options)` -- the whole board, over whichever store it was handed.
//
// `options` takes `secret`, the key a session cookie is signed with; `sink`, where `logger` sends its
// record; `feed`, the event hub; `postLimit`, how many writes a minute one client may make;
// `photoLimit`, how many bytes a photo may be; and `deadline`, how long a request may take.
export application(store: object, sessions: object, options: object = {}) -> object
    val secret = options.secret ?? "a board that made its own secret up"
    val sink = options.sink ?? print
    val feed = options.feed ?? hub({ replay: 64 })
    val writes = options.postLimit ?? 10
    val photos = options.photoLimit ?? 262144

    // **A deadline is an option because it is the one operational number a test has to be able to
    // move.** Five seconds is a page nobody is waiting for any more; five milliseconds is what a
    // suite can prove the refusal with, and neither is a number to sleep through.
    val deadline = options.deadline ?? 5000
    val app = api()

    app.failures(Failure, answer)

    // **The operational guards go outside the ones about an endpoint**, which is what reading in
    // request order means: a request is named, then logged, then bounded, then counted, and only then
    // is who is asking anybody's business.
    val common = [requestId({}), logger(sink), timeout(deadline, {})]
    val known = session(secret, { store: sessions, maxAge: 86400 })

    // Reading. **300 a minute** is a person clicking about, and as of `sluice` 0.4.0 the key is the
    // address that connected -- `req.address` -- rather than a header. **`trustProxy` is deliberately
    // not set here**: a board with nothing in front of it must not take `x-forwarded-for` at its
    // word, that header being a value anybody can write and therefore a limit anybody can walk round.
    // Behind a real proxy this becomes `rateLimit({ ..., trustProxy: true })` and nothing else.
    val browsing = stack(concat(common, [rateLimit({ limit: 300, window: 60000 }), known, formCsrf({})]))

    // Writing. The body is parsed, the token is checked, and only then does a handler run.
    //
    // **`accept` is where the board says what a photo may be**, and it looks at the BYTES: a `.png`
    // may claim `text/plain` and a shell script may claim `image/png`, so the four magic numbers
    // decide and the header decides nothing. A file it refuses is a `415` naming the field and the
    // filename, from `sluice` and before this application's handler runs at all.
    posted(shape: shape) = stack(concat(common, [rateLimit({ limit: writes, window: 60000 }),
                                                 known,
                                                 given(shape, { maxBytes: photos, accept: picture }),
                                                 formCsrf({})]))

    // The JSON API, which is `sluice`'s own `body` and `csrf` -- a client library can set a header and
    // a form cannot, which is the whole difference between this stack and the two above it.
    val calling = stack(concat(common, [rateLimit({ limit: 300, window: 60000 }), known, csrf({})]))

    // A stream is not a request that finishes, so it is not given a deadline and not counted against
    // a window a browser reconnects through.
    val watching = stack([requestId({}), logger(sink)])

    // -- the pages ---------------------------------------------------------------------------------

    app.get("/", browsing((req) -> listPage(store, req)))
    app.get("/new", browsing((req) -> answered(req, { page: "compose" })))
    app.get("/signin", browsing((req) -> answered(req, { page: "signin" })))
    app.get("/signup", browsing((req) -> answered(req, { page: "signup" })))
    app.get("/threads/:id", browsing((req) -> threadPage(store, req)))
    app.get("/people/:name", browsing((req) -> profilePage(store, req)))
    app.get("/admin", browsing((req) -> adminPage(store, sessions, req)))

    // -- the forms ---------------------------------------------------------------------------------

    app.post("/signup", posted(Credentials)((req) -> joined(store, req)))
    app.post("/signin", posted(Credentials)((req) -> signedIn(store, req)))
    app.post("/signout", posted(Nothing)((req) -> signedOut(req)))
    app.post("/theme", posted(Nothing)((req) -> themed(req)))
    app.post("/threads", posted(NewThread)((req) -> started(store, req)))
    app.post("/threads/:id/replies", posted(NewReply)((req) -> replied(store, feed, req)))
    app.post("/threads/:id/delete", posted(Nothing)((req) -> droppedThread(store, req)))
    app.post("/replies/:id/delete", posted(Nothing)((req) -> droppedReply(store, req)))
    app.post("/profile/avatar", posted(Nothing)((req) -> pictured(store, req)))
    app.post("/admin/sessions/:id/revoke", posted(Nothing)((req) -> revoked(sessions, req)))

    // -- the live thread -----------------------------------------------------------------------------

    // **A hub is one-way, so it is a server-sent stream and not a WebSocket** -- a plain `GET`, so
    // every guard already applies to it, and a client that comes back saying where it left off is
    // handed what it missed before anything live.
    app.get("/threads/:id/events", watching((req) -> streamed(feed, req)))

    // -- the JSON API ----------------------------------------------------------------------------------

    app.get("/api/threads", calling((req) -> listJson(store, req)))
    app.get("/api/threads/:id", calling((req) -> threadJson(store, req)))
    app.get("/api/threads/:id/replies", calling((req) -> repliesJson(store, req)))
    app.post("/api/threads", calling(body(NewThread, (req) -> startedJson(store, req))))

    // -- what is on the disk ---------------------------------------------------------------------------

    app.get("/assets/*rest", files("./public", { cacheControl: "max-age=300" }))

    // **A photo is answered by this program and not by `files(root)`**, because a photo's name is the
    // digest of its content: nothing at that address can ever change, so the answer is `immutable`
    // and the `ETag` is the name -- and what is on the disk is not the bytes (see `api/uploads.sl`).
    app.get("/uploads/:name", (req) -> served(req))

    // **A route convention rather than a guard**: the thing asking is a load balancer and not a reader,
    // so it runs under nothing -- no session, no log line and no rate limit -- and what it asks is a
    // round trip to the database rather than a flag in this process.
    app.health("/health", () -> reachable(store))

    // **Last, so that everything above it is tried first.** Routes are matched in the order they were
    // added, and a board answers a page for a path it does not know rather than a problem document a
    // person cannot read.
    app.get("/*rest", browsing((req) -> answered(req, { page: "missing", at: req.path }, 404)))

    app

// -- the pages -------------------------------------------------------------------------------------

async listPage(store: object, req: object)
    val q = req.query ?? {}
    val sort = sortOf(q.sort ?? null)
    val tag = string(q.tag ?? "")
    val text = string(q.q ?? "")

    val got = await store.threads({ sort: sort, tag: tag, q: text, page: q.page ?? 1, size: q.size ?? 20 })

    if !got.ok then return Unavailable(got.error)

    val labels = await store.tags()

    if !labels.ok then return Unavailable(labels.error)

    answered(req, { page: "list",
                    threads: got.value,
                    tags: labels.value,
                    sort: sort,
                    tag: tag,
                    q: text })

async threadPage(store: object, req: object)
    val id = idOf(req.params.id)

    if id == null then return nothingThere(req)

    val got = await store.thread(id)

    if !got.ok then return Unavailable(got.error)
    if got.value == null then return nothingThere(req)

    val rows = await store.replies(id, 0)

    if !rows.ok then return Unavailable(rows.error)

    answered(req, { page: "thread", thread: got.value, replies: rows.value })

async profilePage(store: object, req: object)
    val who = await store.userNamed(req.params.name)

    if !who.ok then return Unavailable(who.error)
    if who.value == null then return nothingThere(req)

    val posts = await store.postsOf(who.value.id)

    if !posts.ok then return Unavailable(posts.error)

    answered(req, { page: "profile",
                    who: who.value,
                    threads: posts.value.threads,
                    replies: posts.value.replies })

// **The page is rendered either way and the STATUS says which**, because the refusal a person needs to
// read is a page and not a problem document -- and a `403` is what says it was a refusal.
async adminPage(store: object, sessions: object, req: object)
    val you = whoIs(req)

    if you == null || you.role != "admin"
        return answered(req, { page: "admin", users: [], sessions: [] }, 403)

    val people = await store.users()

    if !people.ok then return Unavailable(people.error)

    answered(req, { page: "admin", users: people.value, sessions: await sessions.live() }, 200)

nothingThere(req: object) = answered(req, { page: "missing", at: req.path }, 404)

// -- signing in, and joining -------------------------------------------------------------------------

async joined(store: object, req: object)
    val name = trim(req.body.name)
    val password = req.body.password
    val wrong = unusable(name, password)

    if wrong != null then return refused(req, 400, wrong, "signup")

    val made = await store.signUp(name, password, "member")

    // **`23505` is a unique violation**, which is the database saying the one thing this application
    // already has a word for -- and one round trip, where a `select` first would be a race between two
    // people picking the same name.
    if !made.ok && made.code == "23505" then return Taken(name)
    if !made.ok then return Unavailable(made.error)

    req.session.set(made.value)

    moved(req, "/")

// **A shape says what KIND a member is and not what it may hold**, so the checks a board wants that
// `Credentials` cannot make are written here.
unusable(name: string, password: string)
    if len(name) < 2 || len(name) > 30 then return "a name is between 2 and 30 characters"
    if contains(name, "/") || contains(name, " ") then return "a name has no spaces and no slashes"
    if len(password) < 8 then return "a password is at least 8 characters"

    null

async signedIn(store: object, req: object)
    val who = await store.signIn(trim(req.body.name), req.body.password)

    if !who.ok then return Unavailable(who.error)

    // **One answer for a name that is not there and a password that is wrong**, which is the only
    // thing to say: telling them apart hands somebody a way to find out which names exist.
    if who.value == null
        return refused(req, 401, "that name and password do not go together", "signin")

    req.session.set(who.value)

    moved(req, "/")

signedOut(req: object)
    req.session.destroy()

    moved(req, null)

// -- the theme -----------------------------------------------------------------------------------

// **A cookie and not a session member**, so that a reader who has never signed in still gets the theme
// they chose -- and so that the server already knows it when it renders, which is what keeps a dark
// page from flashing white on the way in.
themed(req: object)
    val next = if themeOf(req) == "dark" then "light" else "dark"

    withCookie(moved(req, null), setCookie("theme", next,
        { path: "/", maxAge: 31536000, sameSite: "Lax", httpOnly: false }))

// -- posting -------------------------------------------------------------------------------------

async started(store: object, req: object)
    val you = whoIs(req)

    if you == null then return NotSignedIn("post")

    val title = trim(req.body.title)
    val text = trim(req.body.body)

    if title == "" || text == ""
        return refused(req, 400, "a thread wants a title and something to say", "compose")

    val made = await store.addThread({ title: title,
                                       body: text,
                                       author: you.id,
                                       photo: null,
                                       tags: tagsIn(req.body.tags ?? "") })

    if !made.ok then return Unavailable(made.error)

    val thread = made.value
    val kept = await photo(req)

    if !kept.ok then return refused(req, kept.status, kept.detail, "compose")

    if kept.value != null
        val put = await store.setThreadPhoto(thread.id, kept.value)

        if !put.ok then return Unavailable(put.error)

    moved(req, "/threads/" + string(thread.id))

async replied(store: object, feed: object, req: object)
    val you = whoIs(req)

    if you == null then return NotSignedIn("reply")

    val id = idOf(req.params.id)

    if id == null then return NoSuchThread(req.params.id)

    val text = trim(req.body.body)

    if text == "" then return refused(req, 400, "a reply wants something in it", "thread")

    val made = await store.addReply({ thread: id, body: text, author: you.id, photo: null })

    if !made.ok then return Unavailable(made.error)

    var reply = made.value
    val kept = await photo(req)

    if !kept.ok then return refused(req, kept.status, kept.detail, "thread")

    if kept.value != null
        val put = await store.setReplyPhoto(reply.id, kept.value)

        if !put.ok then return Unavailable(put.error)

        reply = reply with { photo: kept.value }

    // **Published after the row is written and not before**, so a subscriber told about a reply can
    // read it. The topic is the thread, and the ids the hub assigns are that topic's -- which is what
    // lets a client that reconnects say where it left off.
    feed.publish(topicOf(id), { event: "reply", data: reply })

    moved(req, "/threads/" + string(id))

// Whether an uploaded file is a picture this board will keep.
//
// **It is given the bytes and reads the first of them.** An empty part is what a file input somebody
// left alone posts, and it is not a refusal -- there is simply no photo, which every handler here
// already tests for.
picture(file: object) -> boolean
    if len(file.bytes ?? []) == 0 then return true

    kindOf(file.bytes) != null

// The photo a form sent, kept -- or nothing at all, which is the ordinary case.
async photo(req: object) -> object
    val file = pick(req, "photo")

    if file == null then return { ok: true, value: null }

    await keep(file)

// One photo, answered.
//
// **The name IS the content**, so the answer may be cached for ever and a client that has it already
// is told so rather than sent it again: an `ETag` that is the file's own digest cannot be stale.
async served(req: object)
    val name = req.params.name
    val tag = "\"" + name + "\""

    if (req.headers["if-none-match"] ?? "") == tag
        return { status: 304, headers: { ETag: tag, "Cache-Control": Forever }, body: "" }

    val got = await stored(name)

    if !got.ok then return problem(404, "Not Found", "there is no photo called " + name)

    { status: 200,
      headers: { "Content-Type": got.value.type, "Cache-Control": Forever, ETag: tag },
      body: got.value.bytes }

// `slate, Sluice,  ,slate` as `["slate", "sluice"]`.
//
// **Lower case and without repeats**, because a tag is a filter and two spellings of one word are two
// filters that each find half the threads.
tagsIn(said) -> array
    var out = []

    for part in split(string(said), ",")
        val tag = lower(trim(part))

        if tag != "" && !contains(out, tag) && len(out) < 5 then push(out, tag)

    out

// -- taking things away ------------------------------------------------------------------------------

async droppedThread(store: object, req: object)
    val you = whoIs(req)

    if you == null then return NotSignedIn("delete a thread")
    if you.role != "admin" then return NotAllowed("delete")

    val id = idOf(req.params.id)

    if id == null then return NoSuchThread(req.params.id)

    val gone = await store.deleteThread(id)

    if !gone.ok then return Unavailable(gone.error)
    if !gone.value then return NoSuchThread(id)

    moved(req, "/")

// **A reply is the poster's or an administrator's**, which is the one place this board has two ways of
// being allowed to do something.
async droppedReply(store: object, req: object)
    val you = whoIs(req)

    if you == null then return NotSignedIn("delete a reply")

    val id = idOf(req.params.id)

    if id == null then return NoSuchThread(req.params.id)

    val got = await store.reply(id)

    if !got.ok then return Unavailable(got.error)
    if got.value == null then return NoSuchThread(id)
    if you.role != "admin" && got.value.author != you.id then return NotAllowed("delete")

    val gone = await store.deleteReply(id)

    if !gone.ok then return Unavailable(gone.error)

    moved(req, null)

// -- a picture of oneself ------------------------------------------------------------------------------

async pictured(store: object, req: object)
    val you = whoIs(req)

    if you == null then return NotSignedIn("change your picture")

    val kept = await photo(req)

    if !kept.ok then return refused(req, kept.status, kept.detail, "profile")
    if kept.value == null then return refused(req, 400, "no picture was sent", "profile")

    val put = await store.setAvatar(you.id, kept.value)

    if !put.ok then return Unavailable(put.error)

    // **The session is written again, which mints a new id and forgets the old one.** That is
    // `sluice`'s answer to session fixation and it is what keeps the header's picture current without
    // a query on every page.
    req.session.set(you with { avatar: kept.value })

    moved(req, "/people/" + you.name)

// -- revoking somebody's session -------------------------------------------------------------------

async revoked(sessions: object, req: object)
    val you = whoIs(req)

    if you == null then return NotSignedIn("revoke a session")
    if you.role != "admin" then return NotAllowed("revoke")

    await sessions.revoke(req.params.id)

    moved(req, "/admin")

// -- the live thread ---------------------------------------------------------------------------------

topicOf(id: integer) -> string = "thread:" + string(id)

streamed(feed: object, req: object)
    val id = idOf(req.params.id)

    if id == null then return NoSuchThread(req.params.id)

    sse(feed.subscribe(topicOf(id), { lastEventId: lastEventId(req) }))

// -- the JSON API ---------------------------------------------------------------------------------

async listJson(store: object, req: object)
    val q = req.query ?? {}
    val got = await store.threads({ sort: sortOf(q.sort ?? null),
                                    tag: string(q.tag ?? ""),
                                    q: string(q.q ?? ""),
                                    page: q.page ?? 1,
                                    size: q.size ?? 20 })

    if !got.ok then return Unavailable(got.error)

    json(got.value)

async threadJson(store: object, req: object)
    val id = idOf(req.params.id)

    if id == null then return NoSuchThread(req.params.id)

    val got = await store.thread(id)

    if !got.ok then return Unavailable(got.error)
    if got.value == null then return NoSuchThread(id)

    val rows = await store.replies(id, 0)

    if !rows.ok then return Unavailable(rows.error)

    json({ thread: got.value, replies: rows.value })

// **What the page polls while a thread is open**, and what an `EventSource` would be reading if a
// slate program in a browser had one. `after` is the last reply the reader has.
async repliesJson(store: object, req: object)
    val id = idOf(req.params.id)

    if id == null then return NoSuchThread(req.params.id)

    val after = idOf(req.query.after ?? "0") ?? 0
    val rows = await store.replies(id, after)

    if !rows.ok then return Unavailable(rows.error)

    json({ replies: rows.value })

async startedJson(store: object, req: object)
    val you = whoIs(req)

    if you == null then return NotSignedIn("post")

    val made = await store.addThread({ title: trim(req.body.title),
                                       body: trim(req.body.body),
                                       author: you.id,
                                       photo: null,
                                       tags: tagsIn(req.body.tags ?? "") })

    if !made.ok then return Unavailable(made.error)

    json(made.value, 201)

// -- the small things --------------------------------------------------------------------------------

// **A path parameter is text and an id is a number, and the conversion belongs here.** Handing
// `/threads/nonsense` to the database would be a message from PostgreSQL about integer syntax arriving
// as a 503, for a client that simply asked for a thread that is not there.
idOf(text) -> integer | null
    val n = number(string(text ?? ""))

    if n is integer && n > 0 then n else null

// A form that was refused: the page again with the reason on it, or a problem document for a client
// that asked for values.
refused(req: object, status: integer, detail: string, page: string)
    if wantsJson(req) then return problem(status, titleFor(status), detail, { instance: req.path })

    answered(req, { page: page, detail: detail }, status)

// **A health check answers the REASONS it is unwell**, and an empty answer means it is well. A boolean
// would make a failing check a page nobody can act on: whoever is looking at it already knows
// something is wrong and wants to be told which of the things it is.
async reachable(store: object)
    val r = await store.ping()

    if r.ok then [] else ["the board's store is not answering: " + r.error]
