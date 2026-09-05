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

You need PostgreSQL and slate 0.0.31 or later.

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

A cluster of its own, if you would rather not touch a real one:

```
initdb -D /tmp/board-db -U pgtest --auth-host=scram-sha-256 --pwfile=/tmp/pw
pg_ctl -D /tmp/board-db -o "-p 55433" -l /tmp/board-db.log start
PG_URL=postgres://pgtest:slatepw@127.0.0.1:55433/postgres slate scripts/migrate.sl
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

**Three of `tests/postgres.sl`'s tests do not run under `slate test --js`**, `slate:password` not
being on that back end: signing somebody up hashes their password, and a host with no `hash` has
nothing to check. Each asks by trying and skips saying so. Everything else in the file — the
statements, the parameters, the SQLSTATE, the column types — runs on both hosts over
`tests/pgserver.sl`.

**The browser polls a thread rather than reading the stream the server is publishing.** `slate:dom`
has no `EventSource` and `fetch` answers a whole body rather than a stream, so a slate program in a
page has no way to consume server-sent events. `curl` reads the same stream today.
