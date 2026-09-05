# board

A discussion board, written in [slate](https://github.com/slate-language/slate) end to end: the
server, the SQL, the pages, and the program that runs in the browser. It is one application over the
whole stack — [sluice](https://github.com/slate-language/sluice) answering HTTP,
[lath](https://github.com/slate-language/lath) rendering the pages twice,
[mortar](https://github.com/slate-language/mortar) supplying what a page is made of,
[pg](https://github.com/slate-language/pg) speaking to PostgreSQL, and
[logger](https://github.com/slate-language/logger) taking the line each request leaves behind.

**Every page that has anything to say works with no JavaScript at all.** Each form is a real
`<form method="post">`, each link is a real `<a href>`, and the server renders the markup. What the
browser program adds is the thing markup cannot carry: it adopts the page it was sent, installs the
listeners, and from then on a link costs the rows and nothing else — no markup, no stylesheet, no
second copy of the header. One page is deliberately the other way round, and the next section is why.

## When a page is rendered on the server and when it is not

**Server-rendered is the default here and the composer is the one exception**, which is a decision
made per page rather than per application. `app/shell.sl`'s `rendersOnServer(data)` is the whole of
it: `api/render.sl` asks it whether to put markup in the document, and `client.slx` asks the same
function about the same record whether to adopt what is there or to build. Neither side decides
alone — hydrating a container the server left empty is a fault, and mounting over markup that is
already right would throw away the page a reader is looking at and say nothing.

**A page is rendered on the server when its markup is worth sending.** That is content the reader
came for — the thread list, a thread and its replies, somebody's profile — which arrives before the
script and arrives at all for a crawler; and it is the answer to a `POST`, because a form refused with
*a thread wants a title and something to say* has to show that sentence to a browser with no script
running. Everything on this board but one page is one of those two.

**A page is client-only when its markup would be a set of blank controls.** `/new` is the composer:
every value in it lives in a `useRef` until somebody types, so there is nothing in the first render
that the browser is not about to build anyway, and sending it costs a copy of the form on the wire
and a hydration walk over markup that carries no information. So the server answers the document, the
stylesheet-free `<head>`, `<div id="app"></div>` and the state — who is signed in, the CSRF token,
and the reason the last post was refused — and `mount` builds the page into it. The reason a
*refusal* still reaches the reader is that it travels in the state rather than in the markup: the
page mounts and `Problem` renders it.

**What it costs is the one thing worth stating plainly: starting a thread now needs a script.** Every
other form on the board — signing in, joining, replying, deleting, the avatar, signing out — is still
a plain post that works with none, and so is every link, every filter, every sort and the theme. That
is the trade this page is here to show: SSR buys a page that works before and without JavaScript, and
it is worth paying for wherever there is something to read.

## Running it

You need PostgreSQL and slate 0.0.32 or later.

```
slate scripts/migrate.sl
slate scripts/build.sl
PORT=8080 slate server.sl
```

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
| `BOARD_BEHIND_PROXY` | `1` where something in front of this server writes `x-forwarded-for`. Off by default, and the next section is what it promises |

A cluster of its own, if you would rather not touch a real one:

```
initdb -D /tmp/board-db -U pgtest --auth-host=scram-sha-256 --pwfile=/tmp/pw
pg_ctl -D /tmp/board-db -o "-p 55433" -l /tmp/board-db.log start
PG_URL=postgres://pgtest:slatepw@127.0.0.1:55433/postgres slate scripts/migrate.sl
```

## Signing up, signing in, and what the cookie carries

**Two files hold the whole of it.** `api/postgres.sl` is the only one that ever sees a password, and
`api/routes.sl` is the only one that says who may do what — and neither of them writes a cookie, a
token or a hash by hand.

**Signing up turns a password into a record and forgets it.** `slate:crypto`'s `argon2` is Argon2id in
the PHC format, and what goes to the database is that record: the parameters, the salt and the tag,
never the password and never anything reversible into it.

```slate
val stored = await argon2(password)
val r = await db.query("insert into users (name, password, role) values ($1, $2, $3) ...", name, stored, role)
```

**Signing in reads the record and compares, and a name that is not there still costs a hash** — the
`await argon2(password)` in the empty branch — because otherwise the time a sign-in takes says whether
a name exists, which is the one thing a login page must not leak.

```slate
val right = await argon2Verify(row.password, password)

if !right then return { ok: true, value: null }

await upgraded(row, password)
```

**And then it upgrades the stored record, which is the only moment it can.** The parameters travel
inside the record, so raising what the board asks for invalidates nothing — old records go on
verifying under the numbers they were written with, and the plaintext needed to re-hash one is in hand
for exactly this one instant:

```slate
if !argon2NeedsRehash(row.password) then return false

val fresh = await argon2(password)
val put = await db.query("update users set password = $1 where id = $2", fresh, row.id)
```

`argon2NeedsRehash` reads the numbers out of the record and compares them — microseconds, no
derivation, which is why it is the one of the three that is not a promise. A re-hash that cannot be
stored does **not** refuse the sign-in: the password was right and the old record is still a good one,
so a replica that may not be written to is a reason to keep it rather than to lock somebody out.

**The session is a signed id into a store, and the cookie carries nothing else.**

```slate
val known = session(secret, { store: sessions, maxAge: 86400 })
```

`secret` is `BOARD_SECRET`, `sessions` is `api/sessions.sl`'s store, and `maxAge` is a day. What the
browser holds is `{ i: <opaque id>, e: <expiry> }` and an HMAC over it — no name, no role, nothing a
page could read even if it could read the cookie, which it cannot:

```
set-cookie: session=%7B%22i%22%3A%22flGAyBjaBoFf2Sm_gG085PoW%22...; Max-Age=86400; Path=/; SameSite=Lax; HttpOnly; Secure
```

**`HttpOnly` puts it out of reach of script**, so stealing a session means stealing the browser.
**`SameSite=Lax` is the first line against CSRF** — a browser that honours it does not send the cookie
with another site's `POST` at all. **`Secure` follows the scheme rather than being on always**: over
`https://localhost` behind Caddy the same sign-in sets it, and straight at the board over `http://`
it does not — a cookie that insisted on `Secure` would be a session nobody could develop against.
`sluice` reads `x-forwarded-proto` for the answer, which is the header a proxy writes.

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
why this board runs a store at all — the same mechanism the admin page revokes somebody else's session
with. `tests/routes.sl` asserts both halves: `sessions.live()` holds one entry before and none after.

**All of this is same-origin only.** There is no `cors` guard in this application, so a browser will
not let another origin read an answer, and `SameSite=Lax` means it will not send the session with
another origin's form post either. A board that ever wanted a browser client on another host would add
`cors` deliberately and say which origins — it is not something that has been left implicit.

## Run it behind Caddy

**The board speaks plain HTTP on the loopback and never sees a certificate.** TLS, the certificate and
its renewal are the proxy's; the board's whole half of the arrangement is one environment variable.

```
PORT=8099 PG_URL=postgres://pgtest:slatepw@127.0.0.1:55433/postgres BOARD_SECRET=... BOARD_BEHIND_PROXY=1 slate server.sl
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
rate limit believes the leftmost `x-forwarded-for` entry, because behind a proxy the address the socket
saw is the proxy's and every client in the world shares it. With it off — the default — the limit keys
on `req.address` and the header is not looked at, because a header anybody can write is a limit anybody
can walk round.

**`header_up X-Forwarded-For {remote_host}` is what makes the promise true, and Caddy calls it
unnecessary.** Starting with the line above, Caddy warns *"Unnecessary header_up X-Forwarded-For: the
reverse proxy's default behavior is to pass headers to the upstream"* — and passing it on is exactly
the problem, because Caddy **appends** the peer to whatever the client sent and the leftmost entry is
the client's own. Measured against this board, with the same forged header through a proxy without the
line and through one with it:

```
without header_up, forging X-Forwarded-For: 198.51.100.99
x-ratelimit-remaining: 9
x-ratelimit-remaining: 8          a bucket of its own — the forgery was believed
with header_up X-Forwarded-For {remote_host}
x-ratelimit-remaining: 7
x-ratelimit-remaining: 6          the real client's bucket — the forgery was overwritten
```

### What the run proves

Against `caddy run` on `https://localhost` with `tls internal`, the board on `127.0.0.1:8099` and
PostgreSQL on 55433. `curl -k` because Caddy's local root certificate is only installed with `sudo`.

**A sign-in over TLS sets the cookie a session wants**, and the same sign-in straight at the board over
`http://` sets the same cookie without `Secure`:

```
$ curl -k -X POST -d "name=ada&password=...&_csrf=..." https://localhost/signin
set-cookie: session=...; Max-Age=86400; Path=/; SameSite=Lax; HttpOnly; Secure

$ curl -X POST -d "name=ada&password=...&_csrf=..." http://127.0.0.1:8099/signin
set-cookie: session=...; Max-Age=86400; Path=/; SameSite=Lax; HttpOnly
```

**A server-sent stream passes through**, which is the thing a proxy is most likely to break by
buffering. The stream is opened first and a reply posted after it:

```
$ curl -Nk https://localhost/threads/1/events
HTTP/2 200
content-type: text/event-stream
via: 1.1 Caddy

event: reply
id: 1
data: {"id":1,"thread":1,"body":"live from behind a proxy","author_name":"ada",...}
```

**The client the limit counts is the browser and not the proxy.** Four writes, watching one counter:

```
a. through Caddy, no header of its own              x-ratelimit-remaining: 9
b. through Caddy, forging X-Forwarded-For           x-ratelimit-remaining: 8
c. straight at the board, X-Forwarded-For: ::1      X-RateLimit-Remaining: 7
d. straight at the board, another client            X-RateLimit-Remaining: 9
```

`curl` reached `localhost` over IPv6, so the client Caddy saw was `::1` — and (c), which arrives on a
different socket carrying that address as its forwarded client, lands in the **same** bucket as (a) and
(b). The board counted `::1` throughout, never the `127.0.0.1` its own socket saw; (b) shows the
forgery bought nothing, and (d) shows a different client has a window of its own.

**And over the limit is a `429` keyed on that client**, with an exact `Retry-After`, while somebody
else in the same second is unaffected:

```
400 400 400 400 400 400 400 400 400 429     ten writes from 198.51.100.7

HTTP/1.1 429 Status                         the eleventh
Retry-After: 21
X-RateLimit-Remaining: 0

HTTP/1.1 400 Bad Request                    192.0.2.44, in the same second
X-RateLimit-Remaining: 9
```

**The re-hash on sign-in was run against the real database too.** A row written with a record at
`m=8192,t=1` — a board whose numbers were smaller — signed in once through Caddy, and the column
afterwards:

```
$argon2id$v=19$m=8192,t=1,p=1$mG+KJ+/vQvSB3VURrvBTSg$XyEU9fY0qe4jgubiYwFduiMaIRG8XpMKTl69lgmuF3A
sign in: 303
$argon2id$v=19$m=19456,t=2,p=1$5tR+pA2dCqEKC8G+Z6MCZg$rOGaH2tOA/Gv2u8BVM7iYWG/P71Wc1fXvzDMz+eaZS8
```

## The tests

```
slate test tests
slate test --js tests
npm install
NODE_OPTIONS="--import ./tests-dom/setup.mjs" slate test --js tests-dom
```

The first two are the same suite on both hosts and need no database, no socket and nothing to start:
a request is a value, a handler is a function of it, and `await app.handle(request(…))` is the whole
harness. `tests/store.sl` is a second implementation of the store over ordinary arrays, and
`tests/pgserver.sl` is a PostgreSQL server written in slate — so the SQL is checked against the wire
rather than against whichever server happens to be installed.

**Every test in the suite now runs on both hosts**, the six that need a real Argon2id record included:
`slate:crypto`'s `argon2` reached the JavaScript back end in slate 0.0.32, and the three skips this
README used to list are gone. They still ask by trying rather than by naming a host, which is what a
slate program has to do.

The third renders the real pages into a real document. jsdom is a **dev** dependency of this
repository and of nothing else; a program that uses these packages never sees npm.

## What it demonstrates

- **One page, rendered twice.** `app/` holds components that reach for no host at all: the server
  renders them to markup through `lath`'s string host, and the browser adopts that markup and carries
  on. `client.slx` is the only file that knows there is a browser — and one page, the composer, is
  rendered once instead, in the browser, which is what the section above is about.
- **The same route answers a page or the values it was made from.** `?format=json` on any `GET` gives
  the record the markup was rendered from, which is what a hydrated page asks for on every
  navigation, and what makes `curl` a first-class client of a board.
- **Sessions, and a store behind them.** A signed cookie carrying an id into a store, so a session can
  be listed and revoked — which a signed cookie holding the whole session cannot be. `api/sessions.sl`
  shows what the same three functions look like over a table.
- **A password hash that gets stronger without anybody being logged out.** The Argon2id parameters
  travel inside the record, so a sign-in checks against the numbers a password was hashed with and
  then re-hashes it under today's — the one moment the plaintext is in hand. Raising the cost is a
  constant, and every account moves up the next time its owner signs in.
- **CSRF that works for a form.** The double-submit token travels in a hidden field as well as in a
  header, and is minted *before* the page is rendered, so the first form anybody meets already carries
  it.
- **Photographs.** A file input, a multipart body read as bytes, the four raster formats a browser
  shows recognised by their own first bytes, and a file named by the SHA-256 of its content — so the
  name a client sent never reaches the filesystem, the same picture posted twice is one file, and the
  address can be cached for ever.
- **And a picture is processed before it is kept.** The header is read first, so a small file claiming
  a hundred million pixels is a `413` and nothing is ever decoded; then the original is kept and a
  WebP copy is stored beside it — at most 1536 across for a photo, a fixed 128 square for an avatar —
  which is what a page asks for with `?display`. A GIF keeps its original and nothing else, an
  animation being a thing a still would throw away. `slate:image` is the whole of the machinery.
- **A live thread.** `sluice`'s event hub over server-sent events, with `Last-Event-ID` replay: a
  reader that comes back is handed what it missed and nothing it has already seen.
- **Every operational guard.** A request id on every answer, a deadline, a rate limit, a health check
  that is a round trip to the database rather than a flag in the process, and a `SIGTERM` that stops
  taking requests, finishes what is in hand, and only then lets go of the socket.
- **Search, filter, sort, pages and the theme, in the URL.** Every one of them is an ordinary link
  carrying the whole address, so they work on a page whose script never ran — and a cmd-click opens
  the filtered list in a tab. `?theme=dark` is one of them: the server reads it off the request and
  renders a dark page, so there is no first paint in the wrong colours and nothing for a hydrating
  page to correct.
- **A stylesheet is a file, and there is nothing to serve.** Every page is built out of `mortar`
  components, and each of them brings its own sheet with `lath`'s `style(css)` — a `.css` file the
  compiler reads into the program. The board's own layout sits beside its pages the same way
  (`app/list.css`, `app/thread.css`, and four more). So a page carries a `<style>` for exactly the
  components it rendered, there is no `<link rel="stylesheet">` and no second request before the
  first paint, and a hydrating page writes none of them again. No build step, no preprocessor and
  nothing to configure.
- **A boundary.** A thread the page cannot render leaves the header, the footer and the reply form
  where they are.

## What is not finished

**The browser polls a thread rather than reading the stream the server is publishing.** `slate:dom`
has no `EventSource` and `fetch` answers a whole body rather than a stream, so a slate program in a
page has no way to consume server-sent events. `curl` reads the same stream today.
