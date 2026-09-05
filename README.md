# board

A discussion board, written in [slate](https://github.com/slate-language/slate) end to end: the
server, the SQL, the pages, and the program that runs in the browser. It is one application over the
whole stack — [sluice](https://github.com/slate-language/sluice) answering HTTP,
[lath](https://github.com/slate-language/lath) rendering the pages twice,
[pg](https://github.com/slate-language/pg) speaking to PostgreSQL, and
[logger](https://github.com/slate-language/logger) taking the line each request leaves behind.

**Every page works with no JavaScript at all.** Each form is a real `<form method="post">`, each link
is a real `<a href>`, and the server renders the markup. What the browser program adds is the thing
markup cannot carry: it adopts the page it was sent, installs the listeners, and from then on a link
costs the rows and nothing else — no markup, no stylesheet, no second copy of the header.

## Running it

You need PostgreSQL and slate 0.0.30 or later.

```
slate scripts/migrate.sl
slate scripts/build.sl
PORT=8080 slate server.sl
```

`scripts/migrate.sl` applies `schema.sql`, whose every statement is `if not exists`, so running it
twice does what running it once did. `scripts/build.sl` writes `public/app.js`, which is
`slate js client.slx` — one self-contained file, no bundler and nothing to install beside it. The
board runs without it and loses only its live replies and its reload-free posts.

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
  on. `client.slx` is the only file that knows there is a browser.
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
- **A live thread.** `sluice`'s event hub over server-sent events, with `Last-Event-ID` replay: a
  reader that comes back is handed what it missed and nothing it has already seen.
- **Every operational guard.** A request id on every answer, a deadline, a rate limit, a health check
  that is a round trip to the database rather than a flag in the process, and a `SIGTERM` that stops
  taking requests, finishes what is in hand, and only then lets go of the socket.
- **Search, filter, sort and pages, in the URL.** Every one of them is an ordinary link carrying the
  whole address, so they work on a page whose script never ran — and a cmd-click opens the filtered
  list in a tab.
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
