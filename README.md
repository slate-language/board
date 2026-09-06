# board

A discussion board written in [slate](https://github.com/slate-language/slate) end to end: the
server, the SQL, the pages, and the program that runs in the browser. One language, one dependency
graph, one test suite — and the suite runs on both hosts slate has, the interpreter and node.

![The thread list](docs/screenshots/thread-list.png)

## What this is, and why it exists

**It is the reference application for the slate web stack**, and it is a *use* of those packages
rather than a part of any of them:

| | |
|---|---|
| [sluice](https://github.com/slate-language/sluice) | HTTP: routes, guards, sessions, multipart, the event hub, problem documents |
| [lath](https://github.com/slate-language/lath) | the UI, rendered twice — to markup on the server and into the page in a browser |
| [mortar](https://github.com/slate-language/mortar) | what a page is made of, each component carrying its own stylesheet |
| [pg](https://github.com/slate-language/pg) | PostgreSQL, spoken on the same loop that answers HTTP |
| [logger](https://github.com/slate-language/logger) | where a request's log line goes |

**One language across both halves is the point.** A page component is a plain function of its
contexts, so the server renders it to a string and the browser adopts that same markup and carries
on. `client.slx` is the only file in the repository that knows there is a browser at all, and `api/`
is the only half that knows there is a database. Neither half imports the other's host.

**Every page that has anything to say works with no JavaScript.** Each form is a real
`<form method="post">`, each link is a real `<a href>`, the sort, the filter, the pager and the
theme are all in the URL, and the server renders the markup. What the browser program adds is the
thing markup cannot carry: it adopts the page it was sent, installs the listeners, and from then on
a link costs the rows and nothing else — no markup, no stylesheet, no second copy of the header.

**And one suite runs on two hosts.** A request is a value and a handler is a function of it, so
`await app.handle(request(…))` is the whole harness — no socket, no database, nothing to start.
`slate test tests` runs it under the interpreter and `slate test --js tests` runs the same files
compiled to JavaScript under node.

Where a package could not do something this board needed, the package was changed rather than
written around. The list of what that turned up is at the end.

## Run it

You need PostgreSQL and **slate 0.0.34 or later**.

```
brew install slate-language/tap/slate
git clone https://github.com/slate-language/board
cd board
slate fetch
```

`slate fetch` downloads the five packages in `package.sl` and records their hashes in `slate.sum`.
`slate add <pkg>` is what puts a new one in the manifest; `slate deps` says whether anything in the
graph is unrecorded.

A cluster of its own, if you would rather not touch a real one:

```
printf 'slatepw' > /tmp/board-pw
initdb -D /tmp/board-db -U pgtest --auth-host=scram-sha-256 --pwfile=/tmp/board-pw
pg_ctl -D /tmp/board-db -o "-p 55433" -l /tmp/board-db.log start
```

Then the schema, the browser program, and the server:

```
export PG_URL=postgres://pgtest:slatepw@127.0.0.1:55433/postgres
slate scripts/migrate.sl
slate scripts/build.sl
PORT=8080 BOARD_SECRET=a-long-random-string slate server.sl
```

Open **http://127.0.0.1:8080**, follow *Join*, and make an account — the first thing to do is post a
thread with a photograph on it, which is what the rest of this tour is about. The board prints its
address and its whole route table on the way up.

`scripts/migrate.sl` applies `schema.sql`, whose every statement is `if not exists`, so running it
twice does what running it once did. `scripts/build.sl` writes `public/app.js`, which is
`slate js client.slx` — one self-contained file, no bundler and nothing to install beside it. It is
the only thing under `public/` and the only thing the board serves off the disk; the stylesheets
travel inside the program. The board runs without it and loses only its live replies and its
reload-free posts.

| | |
|---|---|
| `PG_URL` | `postgres://user:secret@host/database`. With none, `pg` connects wherever `psql` would |
| `PORT` | `0` asks the kernel for one, which is what the default does; the server says which |
| `BOARD_SECRET` | the key a session cookie is signed with. **Set it**: a generated one signs everybody out on every restart, and the server says so on `stderr` |
| `BOARD_BEHIND_PROXY` | `1` where something in front of this server writes `x-forwarded-for`. Off by default, and *Behind Caddy* below is what it promises |

Stop it with `SIGTERM`: new requests are refused, what is in hand finishes, and only then is the
socket let go. `pg_ctl -D /tmp/board-db stop` puts the cluster away.

## A request's journey

Seven files, in the order a request meets them.

### 1. `server.sl` — the wiring, and nothing else

It opens the database, builds the store, hands both to `application()` and serves it. No route, no
SQL and no markup is in this file.

```slate
val store = opened.value
val sessions = sessionStore({})
val app = application(store, sessions, { secret: secret(), sink: said, trustProxy: behindProxy() })

val port = portOf(env("PORT") ?? "0")
val server = serve(port, app)

onShutdown(() -> stopping(app, server, store))
```

**`store` is a plain object of functions**, each answering `{ ok: true, value }` or
`{ ok: false, error, code }`. `api/postgres.sl` is one implementation over `pg`;
`tests/store.sl` is a second over ordinary arrays, which is how every route in the board is driven
with no database anywhere.

### 2. `api/routes.sl` — the guards, outermost first

A route is a handler wrapped in a stack of guards, and they are written in the order a request meets
them: named, logged, bounded, counted, and only then is who is asking anybody's business.

```slate
val common = [requestId({}), logger(sink), timeout(deadline, {})]
val known = session(secret, { store: sessions, maxAge: 86400 })

reading() = rateLimit({ limit: 300, window: 60000, trustProxy: trusted })

val browsing = stack(concat(common, [reading(), known, formCsrf({})]))

posted(shape: shape) = stack(concat(common, [rateLimit({ limit: writes, window: 60000,
                                                         trustProxy: trusted }),
                                             known,
                                             given(shape, { maxBytes: photos, accept: picture }),
                                             formCsrf({})]))
```

**`given(Shape)` is the validator and the declaration is the schema.** `type NewThread = { title:
string, body: string, tags?: string, back?: string }` is checked against a form, a multipart body or
a JSON one alike, and a body that does not fit is a `400` carrying *every* reason rather than the
first. `accept: picture` looks at the bytes a file starts with, so a shell script labelled
`image/png` is a `415` naming the field and the filename before any handler runs.

**A guard refuses with a problem document and a handler answers a page.** A `413` and a `415` come
back as RFC 9457 JSON for a browser and a client library alike; a `400` a handler decided is the
page again with the reason on it.

### 3. The route table — a page or the values it was made from

```slate
app.get("/", browsing((req) -> listPage(store, req)))
app.get("/threads/:id", browsing((req) -> threadPage(store, req)))
app.post("/threads", posted(NewThread)((req) -> started(store, req)))
app.post("/threads/:id/replies", posted(NewReply)((req) -> replied(store, feed, req)))
app.get("/threads/:id/events", watching((req) -> streamed(feed, req)))
app.get("/uploads/:name", (req) -> served(req))
app.health("/health", () -> reachable(store))
```

`?format=json` on any `GET` answers the record the markup was rendered from. That is what a hydrated
page asks for on every navigation, and it is what makes `curl` a first-class client of the board.

### 4. `api/render.sl` — one page twice, and the state that travels with it

```slate
export answered(req: object, data: object, status: integer = 200) -> object
    val at = addressOf(req)
    val state = { url: at, data: data, user: whoIs(req), csrf: req.csrf ?? "", theme: themeOf(at) }

    if wantsJson(req) then return json(state, status)

    addressIs(state.url)

    val markup = if !rendersOnServer(data)
        ""
    else
        html(mount(App({ nav: { url: state.url, go: null, replace: null }, data: data,
                         user: state.user, csrf: state.csrf, send: null })))

    { status: status,
      headers: { "Content-Type": "text/html; charset=utf-8" },
      body: page(titleOf(data), state.theme, markup, state) }
```

`app/shell.sl` writes the document around that markup, and the record it was rendered from goes into
the page beside it:

```slate
val tail = "</div>
<script type=\"application/json\" id=\"board-state\">" + stateText(state) + "</script>
<script src=\"/assets/app.js\" defer></script>
</body>
</html>
"
```

**Every `<` inside the state is written as its JSON unicode escape**, that being the one character
that can end a `<script>` early — a post whose text contains `</script>` would otherwise close the
element and have the rest of the document parsed as HTML. Escaping the character rather than the sequence is what
makes that true of anything anybody can type.

### 5. `client.slx` — adopt what was sent, or build what was not

```slate
start() =
    val state = started()
    val into = domHost("#app")
    val page = <Root state={state}/>

    if rendersOnServer(state.data) then hydrate(page, into) else mount(page, into)
```

**`hydrate` walks the tree the same way `mount` does and takes every node it would have created from
the page instead**, so the page records no DOM mutations at all on the way in. What it gains is the
one thing markup cannot carry: event listeners.

**Which of the two this is, is the server's answer read back rather than a guess.**
`app/shell.sl`'s `rendersOnServer(data)` is the single place that decides, and both sides ask it
about the same record. Hydrating a container the server left empty is a fault, and mounting over
markup that is already right would throw away the page a reader is looking at and say nothing.

From then on, a link is `fetch` and a `setState`:

```slate
async pull(to: string)
    val got = await fetch(asJson(to), { headers: { Accept: "application/json" } })

    if !got.ok then return null

    val parsed = parseJSON(got.value.body)

    if !parsed.ok then return null

    setState(parsed.value)
```

### 6. The hub — a reply, published to whoever is reading

A reply that is stored is published to the thread's topic, and the stream is an ordinary `GET`, so
every guard already applies to it:

```slate
feed.publish(topicOf(id), { event: "reply", data: reply })
```

```slate
streamed(feed: object, req: object)
    val id = idOf(req.params.id)

    if id == null then return NoSuchThread(req.params.id)

    sse(feed.subscribe(topicOf(id), { lastEventId: lastEventId(req) }))
```

`Last-Event-ID` is replay: a reader that reconnects is handed what it missed, in order, before
anything live. `curl -N http://127.0.0.1:8080/threads/1/events` reads it.

**The browser polls instead, and that is the one thing here that is standing in for something
better.** `slate:dom` has no `EventSource`, and slate's `fetch` answers a whole body rather than a
stream, so a slate program in a page has no way to consume server-sent events. One name on
`slate:dom` closes it.

## The pages, and what they are made of

`app/pages.slx` is the whole of what this board *is* — which rows go in the list, what a thread page
holds, where the filters sit — and every piece it is built out of comes from `mortar`.

```slate
export App(props: object) =
    val out = <Nav.Provider value={nav}>
        <PostContext.Provider value={{ send: props.send ?? null }}>
            <Session.Provider value={session}>
                <Board.Provider value={props.data ?? { page: "missing", at: "/" }}>
                    <Theme class="board">
                        <Frame>{router(routes, nav.url)}</Frame>
                    </Theme>
                </Board.Provider>
            </Session.Provider>
        </PostContext.Provider>
    </Nav.Provider>
```

**A stylesheet here is a file the compiler reads into the program, and there is nothing to serve.**
Each component registers its own sheet with `lath`'s `style(css)`, and the board's own layout sits
beside its pages the same way — `app/list.css`, `app/thread.css` and four more, each brought in with
`import sheet from "./x.css"`. The string host writes one `<style>` per distinct sheet in front of
the markup; the DOM host claims those on the way in and writes none of them again. So there is no
`<link rel="stylesheet">`, no second request before the first paint, and a page that renders no
thread list ships no thread-list CSS.

**Not one colour, size, radius or duration is written in this repository.** Every value in the six
board sheets is a `var(--m-…)` out of `mortar`'s tokens, which is what makes the whole board turn
over on one attribute:

![The same list, dark](docs/screenshots/thread-list-dark.png)

**The theme is `?theme=dark` in the address** — no cookie, no `/theme` route. The server reads it off
the request and renders the right colours the first time, so there is no first paint in the wrong
ones and nothing for a hydrating page to correct. It is an ordinary link, so it works on a page whose
script never ran, and a `?theme` nobody recognises is a light page rather than a fault.

The layout is the tokens' own, so a narrow window is the same page:

<img src="docs/screenshots/thread-list-mobile.png" alt="The thread list at 390 pixels wide" width="390">

### The one client-only page, and why

**Server-rendered is the default and the composer is the exception**, which is a decision made per
page rather than per application.

![Starting a thread](docs/screenshots/composer.png)

**A page is rendered on the server when its markup is worth sending** — content the reader came for,
which arrives before the script and arrives at all for a crawler, and the answer to a `POST`, because
a form refused with *a thread wants a title and something to say* has to show that sentence to a
browser with no script running.

**A page is client-only when its markup would be a set of blank controls.** `/new` is that page:
every value in it lives in a `useRef` until somebody types, so there is nothing in the first render
the browser is not about to build anyway, and sending it costs a copy of the form on the wire and a
hydration walk over markup carrying no information. The server answers the document, the empty
`<div id="app"></div>` and the state — who is signed in, the CSRF token, and the reason the last post
was refused — and `mount` builds the page into it. A *refusal* still reaches the reader because it
travels in the state rather than in the markup.

**What it costs is worth stating plainly: starting a thread needs a script.** Every other form on the
board — signing in, joining, replying, deleting, the avatar, signing out — is still a plain post that
works with none. That is the trade this page is here to show.

## Photographs and avatars

![A thread with a photograph and its replies](docs/screenshots/thread.png)

**What a photo is is read off its first bytes.** PNG, JPEG, GIF and WebP, each by its own magic
number; the `Content-Type` a client wrote decides nothing. **An SVG is deliberately not among them**:
it is a document with script in it, and serving one from this origin would be serving somebody else's
JavaScript to the board's readers.

**The size is asked of the header before anything is decoded.** A decoded picture is
`width × height × channels` bytes however small the file was, so a four-kilobyte PNG claiming 20,000
square is 1.2 GB the moment anything reads it — a compression bomb in a picture's clothes, and one
that walks straight past a limit on bytes uploaded. `imageShape` reads the header and decodes
nothing, so a picture over 40,000,000 pixels is a `413` naming the size it claimed, and no memory is
ever asked for. Nothing at all is written for a picture that cannot be processed: the sniff, the size
and the whole derivation happen in memory first.

**A photo is named by the base64url of its own SHA-256.** So the name a client sent never reaches the
filesystem, the same picture posted twice is one file, and the address is immutable — which is what
earns a year-long `Cache-Control` and an `ETag` that cannot be stale:

```slate
async served(req: object)
    val name = string(req.params.name ?? "")

    if !minted(name) then return problem(404, "Not Found", "there is no photo at that address")

    val wanted = if has(req.query ?? {}, "display") then (await display(name)) ?? name else name
    val tag = "\"" + wanted + "\""

    if (req.headers["if-none-match"] ?? "") == tag
        return { status: 304, headers: { ETag: tag, "Cache-Control": Forever }, body: "" }
```

**`minted` is the first line and the order is the point** — everything else reads a name a request
wrote. It is a whitelist: 43 base64url characters, one dot, one of four extensions, exactly. That
leaves no room for a slash, a dot pair, a NUL or a percent escape, so `../../etc/passwd`,
`..%2fserver.sl` and `a%00.png` are refused by one sentence and none of them is a case anybody had to
think of.

**A post's photo keeps the original and stores a WebP display copy beside it**, at most 1536 across;
an avatar's is a fixed 128 square, cut before it is scaled — cutting first can never ask for more
pixels than were uploaded, where covering 128 with a 40,000 × 1,000 panorama asks for 650 million.
Both numbers are `mortar`'s own, doubled for a retina screen. A GIF keeps its original and nothing
else: `readImage` answers the first frame, and a still of a reaction GIF has thrown away what was
posted.

**The two files cannot be named after one another**, each being the digest of its *own* bytes: a
derived name would make that address a promise about how this board resizes, and it is cached for a
year. So `<original>.display` is one line beside the original holding the copy's name — and nothing
can ever ask for it, two dots not being a name `minted` takes.

**Which of the two a page asks for is two lines in `app/parts.slx`:**

```slate
export pictureOf(file) = if file == null then null else "/uploads/" + string(file) + "?display"
export originalOf(file) = if file == null then null else "/uploads/" + string(file)
```

A picture is rendered from the first and the *view original* link under it from the second. Where
there is no display copy — a GIF, or a host with no `slate:image` — both addresses answer the same
bytes, so the link is never a broken promise and never has to be hidden. It is a plain `<a href>` and
not a `Link`: the address is a file rather than a page of this application, so what it wants is the
browser fetching it.

## Signing up, signing in, and what the cookie carries

![Signing in](docs/screenshots/sign-in.png)

**Two files hold the whole of it.** `api/postgres.sl` is the only one that ever sees a password, and
`api/routes.sl` is the only one that says who may do what — and neither writes a cookie, a token or a
hash by hand.

**Signing up turns a password into a record and forgets it.** `slate:crypto`'s `argon2` is Argon2id
in the PHC format, and what goes to the database is that record — the parameters, the salt and the
tag, never the password and never anything reversible into it.

```slate
val stored = await argon2(password)
val r = await db.query("insert into users (name, password, role) values ($1, $2, $3) ...", name, stored, role)
```

**Signing in reads the record and compares, and a name that is not there still costs a hash** — the
`await argon2(password)` in the empty branch — because otherwise the time a sign-in takes says
whether a name exists, which is the one thing a login page must not leak.

```slate
val right = await argon2Verify(row.password, password)

if !right then return { ok: true, value: null }

await upgraded(row, password)
```

**And then it upgrades the stored record, which is the only moment it can.** The parameters travel
inside the record, so raising what the board asks for invalidates nothing — old records go on
verifying under the numbers they were written with, and the plaintext needed to re-hash one is in
hand for exactly this instant:

```slate
if !argon2NeedsRehash(row.password) then return false

val fresh = await argon2(password)
val put = await db.query("update users set password = $1 where id = $2", fresh, row.id)
```

`argon2NeedsRehash` reads the numbers out of the record and compares them — microseconds, no
derivation. A re-hash that cannot be stored does **not** refuse the sign-in: the password was right
and the old record is still a good one, so a replica that may not be written to is a reason to keep
it rather than to lock somebody out.

**The session is a signed id into a store, and the cookie carries nothing else.**

```slate
val known = session(secret, { store: sessions, maxAge: 86400 })
```

What the browser holds is `{ i: <opaque id>, e: <expiry> }` and an HMAC over it — no name, no role,
nothing a page could read even if it could read the cookie, which it cannot:

```
set-cookie: session=%7B%22i%22%3A%22flGAyBjaBoFf2Sm_gG085PoW%22...; Max-Age=86400; Path=/; SameSite=Lax; HttpOnly; Secure
```

**`HttpOnly` puts it out of reach of script**, so stealing a session means stealing the browser.
**`SameSite=Lax` is the first line against CSRF** — a browser that honours it does not send the
cookie with another site's `POST` at all. **`Secure` follows the scheme rather than being on
always**: over `https://localhost` behind a proxy the same sign-in sets it, and straight at the board
over `http://` it does not — a cookie that insisted on `Secure` would be a session nobody could
develop against. `sluice` reads `x-forwarded-proto` for the answer.

**Every mutating form carries a token as well.** `formCsrf` in `api/forms.sl` mints a random one into
a cookie a script *can* read and requires it back in the `_csrf` field or the `x-csrf-token` header on
every `POST`, `PUT`, `PATCH` and `DELETE`; the JSON API uses `sluice`'s own `csrf({})`, a header being
something a client library can set and a plain form cannot. A form posted from another site carries
the cookie — browsers send those — and cannot read it, because reading it needs script running on this
origin. The token is minted *before* the page is rendered, so the first form anybody meets already
carries it.

**Signing out revokes rather than forgets.**

```slate
signedOut(req)
    req.session.destroy()
```

`destroy()` deletes the entry from the store *and* clears the cookie, so a copy of the cookie taken
beforehand is nobody. That is the half a signed cookie holding the whole session cannot do, and it is
why this board runs a store at all — the same mechanism the admin page revokes somebody else's
session with. `tests/routes.sl` asserts both halves: `sessions.live()` holds one entry before and
none after.

**All of this is same-origin only.** There is no `cors` guard in this application, so a browser will
not let another origin read an answer, and `SameSite=Lax` means it will not send the session with
another origin's form post either. A board that wanted a browser client on another host would add
`cors` deliberately and say which origins.

## Behind Caddy

**The board speaks plain HTTP on the loopback and never sees a certificate.** TLS, the certificate
and its renewal are the proxy's; the board's whole half of the arrangement is one environment
variable.

```
PORT=8099 PG_URL=... BOARD_SECRET=... BOARD_BEHIND_PROXY=1 slate server.sl
caddy run
```

The `Caddyfile` at the root of this repository is the other half:

```
localhost {
	tls internal

	reverse_proxy 127.0.0.1:8099 {
		header_up X-Forwarded-For {remote_host}
	}
}
```

**`BOARD_BEHIND_PROXY=1` is a promise about the deployment and not a convenience.** With it on, the
rate limit believes the leftmost `x-forwarded-for` entry, because behind a proxy the address the
socket saw is the proxy's and every client in the world shares it. With it off — the default — the
limit keys on `req.address` and the header is not looked at, because a header anybody can write is a
limit anybody can walk round.

**`header_up X-Forwarded-For {remote_host}` is what makes the promise true, and Caddy calls it
unnecessary.** Caddy warns *"the reverse proxy's default behavior is to pass headers to the
upstream"* — and passing it on is exactly the problem, because Caddy **appends** the peer to whatever
the client sent, so the leftmost entry is the client's own. The same forged header through a proxy
without the line and through one with it:

```
without header_up, forging X-Forwarded-For: 198.51.100.99
x-ratelimit-remaining: 9
x-ratelimit-remaining: 8          a bucket of its own -- the forgery was believed
with header_up X-Forwarded-For {remote_host}
x-ratelimit-remaining: 7
x-ratelimit-remaining: 6          the real client's bucket -- the forgery was overwritten
```

The rate-limit headers are the instrument for *which client is this counted as*, and they are how the
rest of the arrangement is checked: an event stream passing through unbuffered, `Secure` appearing
over TLS and not over plain HTTP, and a `429` with an exact `Retry-After` that leaves everybody else
in the same second unaffected.

## Testing

```
slate test tests
slate test --js tests
NODE_OPTIONS="--import ./tests-dom/setup.mjs" slate test --js tests-dom
```

Three commands and all three have to be green. The third needs `npm install` once and prints a wall
of `Could not parse CSS stylesheet` from jsdom's CSS parser, which does not read the native nesting
every `mortar` sheet is written in — noise, not a failure.

| | |
|---|---|
| `slate test tests` | every route, page, statement and upload, under the interpreter |
| `slate test --js tests` | the same suite compiled to JavaScript and run under node |
| the jsdom one | the real pages adopted by a real document — hydration, events, mutations |

**The first two are the same suite on two hosts and need no database, no socket and nothing to
start.** `tests/store.sl` is a second implementation of the store over ordinary arrays, and
`tests/pgserver.sl` is a PostgreSQL server written in slate — so the SQL is checked against the wire
rather than against whichever server happens to be installed.

**jsdom is what the first two cannot reach.** They render to a string, which says what the markup
says and nothing about what a browser makes of it: whether the page can be *adopted* at all, whether
hydration writes anything it did not have to, whether a form the framework attached really submits
without a reload. `tests-dom/` measures that with jsdom's own `MutationObserver` — the browser's
answer rather than the framework's. jsdom is a dev dependency of this repository and of nothing else;
a program that uses these packages never sees npm.

**`slate test tests --only <substring>` runs the tests whose name contains it** and prepares no file
that has nothing chosen, which is what to reach for while working on one thing: `--only PHOTO`,
`--only THE_THEME`, `--only 429`. A filter that matches nothing is a failure and not an empty
success.

**A test asks the host by trying**, a slate program having no name for the host it is running on.
Whether a socket can be bound, whether `argon2` can hash and whether a picture can be decoded are
each a call in a `try`, and a test that cannot run says what it is *waiting for* rather than what is
absent.

**Fixtures are opened by a `@setup` and put back by a `@teardown`.** `tests/routes.sl` builds a whole
board in its setup and closes its event streams and sweeps its photos in its teardown, so a failed
assertion still leaves the working directory as it found it. **A hook is outside the runner's
per-test drain**, so it is for state and never for anything on the event loop: a setup that leaves a
live handle hangs the test after it with no output at all, and a teardown cannot put out a timer the
body left.

**And what a live run covers is what no suite can**: a real socket, a real multipart body, a real
PostgreSQL and a real signal. *Run it*, above, is the recipe.

## What this board found in the stack

Every one of these was a gap this application walked into, and each was fixed in the package rather
than spelled around here — a workaround shipped in reading material teaches itself to everybody who
follows.

| what broke | where | fixed in |
|---|---|---|
| Two adjacent text children came back from the markup as one text node, so `<h2>{n} replies</h2>` could not be hydrated | `lath` | 0.5.1 writes a separating comment, as React does |
| A text child that is the empty string vanished, so `<textarea>{value ?? ""}</textarea>` disagreed across hosts | `lath` | 0.5.1 decides it in the tree instead |
| `value` was set as a property without comparing what was there, and `rows={5}` was compared against the page's `"5"` — mutations on a hydration that should record none | `lath` | 0.5.1 compares before it writes |
| An attribute whose value is `false` wrote `required="false"`, which a browser reads as *required* | `lath` | 0.5.1: `false` and `null` are no attribute, which is HTML's own rule |
| Asking for the query installed a navigator, so the header's theme control quietly took over what following a link meant — in a real browser the address bar moved and the page never re-rendered | `lath` | 0.5.2: a page's own `navigateWith` outranks the built-in one |
| The same control took the back button, `slate:dom` keeping one `onNavigate` handler for the whole program | `lath` | 0.5.3: `usePath` does not listen where a page installed a navigator |
| `multipart` read the body as text, so a `.png` was the same value as no body at all | `sluice` | 0.4.0 reads `req.bytes` |
| A refused upload's media type was under the problem document's own `type`, which RFC 9457 defines as the *problem's* type | `sluice` | 0.4.1 moved it to `mediaType` |
| `Theme` faulted on a `?theme` word it did not know — and a query string is something anybody may type | `mortar` | 0.2.1 reads an unknown word as the default |
| Changing the theme threw away the filter and the sort the reader was on | `mortar` | 0.2.1's setter keeps the rest of the query |
| `slate:fs` could write text and not bytes, so a photograph could not be stored | slate | 0.0.31 added `writeBytes` |
| Argon2id ran nowhere but the interpreter, so six tests skipped under `--js` | slate | 0.0.32 put `argon2`/`argon2Verify` in `slate:crypto` on both back ends |

Four are still open, and each is a bullet rather than a workaround:

- **`fetch` refuses a relative URL**, which is the ordinary thing a page asks for and the only thing a
  page can ask for: nothing in a browser program knows its own origin. `fetch("/signup?format=json")`
  answers `{ ok: false, error: "`/signup?format=json` is not an http or https URL" }` — the rule
  `parse_url` applies for a *server* making a request, read again in a host where the address bar is
  the base. So the record a followed link costs is never fetched: a link to a page whose record the
  browser already holds renders correctly, and a link to one it does not — the composer, a profile, a
  thread — sits on *Fetching…*, which is what `Pending` renders while the values are on their way.
  Writing `location().origin + to` here would be exactly the workaround this table exists to avoid.

- **`slate:image` is not on the JavaScript back end.** So a display copy is something this board makes
  under the interpreter and simply does not make under node — which is why `?display` falls back to
  the original rather than answering a 404, and why four tests skip there.
- **`slate:dom` has no `EventSource`**, so the browser polls a thread while the server publishes a
  perfectly good stream that `curl` reads.
- **`imageShape` refuses a header of more than 2^28 pixels and says `unknown image type`**, where the
  documented example is a PNG claiming 20,000 square. It costs this board nothing — such a file is
  refused either way — but a program written from the documentation gets the wrong answer for the
  case the documentation is about.

## Licence

ISC. See [LICENSE](LICENSE).
