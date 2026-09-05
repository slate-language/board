// The board's store, over PostgreSQL. **This is the only file in the application that knows any SQL**
// and the only one that hashes a password.
//
// It is a plain object of functions, which is what `api/routes.sl` is written against -- so nothing
// above it sees a connection, a row, a SQLSTATE or a `pg` import, and `tests/store.sl` hands the same
// routes an implementation over ordinary arrays with no database anywhere.
//
// **Every call answers a result** -- `{ ok: true, value }` or `{ ok: false, error, code }`, `code`
// being the SQLSTATE where the server sent one. That is slate's rule for anything that reaches the
// network and it is what `pg` already answers: a database that is down, a role that may not read a
// table and a unique index that refused a row are all things a service turns into a status rather
// than a defect in itself.
//
// **Every call here is a promise on the same loop that is answering HTTP**, which is what `pg`
// speaking the wire protocol in slate buys: a handler waiting for PostgreSQL is the only thing
// waiting.

import { pg } from pg
import { argon2, argon2Verify } from slate:crypto
import { env } from slate:process

// What to connect with, read from the environment. **A deployment already carries this**, and a
// program that invented names of its own for it would be one more thing to configure.
//
// With nothing set, `pg` reads what `psql` reads -- `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`,
// `PGDATABASE` -- so a machine where `psql` connects is a machine where this connects.
export configuration() = env("PG_URL") ?? (env("DATABASE_URL") ?? {})

// `postgres(config)` -- connect and answer the store, or say why not.
//
// **It answers a result and does not throw.** A database that is not up, a password that is wrong
// and a role that may not read a table are all things a program handles rather than defects in it.
//
// **The schema is NOT applied here.** `scripts/migrate.sl` reads `schema.sql` and runs it, because a
// service that is deployed twice wants its schema somewhere a review can see it rather than in a
// string beside the queries.
export async postgres(config) -> object
    val made = await pg(config)

    if !made.ok then return { ok: false, error: made.error }

    { ok: true, value: store(made.value) }

// -- what a client may say about ordering, and nothing else ----------------------------------------
//
// **The three orders are constants chosen by a name, never text pasted into the statement.** A sort
// key is the one part of a query that cannot be a parameter -- the server parses the statement before
// it is given a value -- so it is the one place an application has to hold the list itself. What
// arrives from a client selects one of these; anything else is `newest`.
val Orders = { newest: "t.made desc, t.id desc",
               active: "t.active desc, t.id desc",
               busiest: "t.replies desc, t.made desc, t.id desc" }

export orderNamed(sort) -> string = Orders[if has(Orders, string(sort)) then string(sort) else "newest"]

// The columns a thread is read with, and the author's name and avatar beside it. **`made` and
// `active` come back as epoch SECONDS** rather than as timestamps: what a page does with either is
// render it, and an integer is a value every JSON encoder, every host and both back ends agree
// about.
val ThreadColumns = "t.id, t.title, t.body, t.photo, t.replies, u.id as author, u.name as author_name,
    u.avatar as author_avatar, extract(epoch from t.made)::bigint as made,
    extract(epoch from t.active)::bigint as active"

val ReplyColumns = "r.id, r.thread, r.body, r.photo, u.id as author, u.name as author_name,
    u.avatar as author_avatar, extract(epoch from r.made)::bigint as made"

val UserColumns = "u.id, u.name, u.role, u.avatar, extract(epoch from u.made)::bigint as made"

// -- the store -------------------------------------------------------------------------------------

store(db: object) -> object
    // **The health check is a round trip and not a flag.** A connection object that still exists says
    // nothing about a database that has gone; a `select` that comes back says it is there.
    async ping()
        val r = await db.query("select 1 as up")

        if !r.ok then return refused(r)

        { ok: true, value: true }

    // -- people ------------------------------------------------------------------------------------

    // **The derivation runs on a thread pool and the loop carries on**, which is what makes
    // `argon2` a promise: a tenth of a second on the loop is a tenth of a second in which
    // this server answers nobody, so ten simultaneous sign-ups would be a second of a dead process.
    async signUp(name: string, password: string, role: string)
        val stored = await argon2(password)
        val r = await db.query("insert into users (name, password, role) values ($1, $2, $3)
            returning id, name, role, avatar, extract(epoch from made)::bigint as made",
            name, stored, role)

        if !r.ok then return refused(r)

        { ok: true, value: r.value.rows[0] }

    // **The record is read first and compared second**, and a name that is not there still costs a
    // check -- otherwise the time this takes says whether a name exists, which is the one thing a
    // sign-in page must not leak.
    async signIn(name: string, password: string)
        val r = await db.query("select id, name, role, avatar, password,
            extract(epoch from made)::bigint as made from users where name = $1", name)

        if !r.ok then return refused(r)

        val rows = r.value.rows

        if len(rows) == 0
            await argon2(password)

            return { ok: true, value: null }

        val row = rows[0]
        val right = await argon2Verify(row.password, password)

        if !right then return { ok: true, value: null }

        { ok: true, value: withoutPassword(row) }

    async user(id: integer)
        val r = await db.query("select " + UserColumns + " from users u where u.id = $1", id)

        if !r.ok then return refused(r)

        { ok: true, value: first(r.value.rows) }

    async userNamed(name: string)
        val r = await db.query("select " + UserColumns + " from users u where u.name = $1", name)

        if !r.ok then return refused(r)

        { ok: true, value: first(r.value.rows) }

    // Everybody, for the admin page. A board with a hundred thousand accounts wants this paged the
    // way the thread list is; a board this size wants to be read in one screen.
    async users()
        val r = await db.query("select " + UserColumns + " from users u order by u.id")

        if !r.ok then return refused(r)

        { ok: true, value: r.value.rows }

    async setAvatar(id: integer, file)
        val r = await db.query("update users set avatar = $1 where id = $2", file, id)

        if !r.ok then return refused(r)

        { ok: true, value: r.value.count > 0 }

    // -- threads -----------------------------------------------------------------------------------

    // A page of the list, and how many there are altogether.
    //
    // **LIMIT/OFFSET and not a keyset**, which is a decision this application can defend rather than a
    // default it fell into. A keyset -- `where (made, id) < ($1, $2)` -- is the faster answer and the
    // stable one under writes, and it cannot do the two things this page is: **jump to page 7**, and
    // **say how many pages there are**. Both are on the screen, so both have to be answerable. The
    // cost is that the database walks and discards `offset` rows, which is nothing at this size and
    // is the thing to change first at a million threads -- at which point the page numbers go too.
    async threads(options: object)
        val where = conditions(options)
        val order = orderNamed(options.sort ?? "newest")
        val size = bounded(options.size ?? 20, 1, 50)
        val page = max(1, whole(options.page ?? 1, 1))
        val skip = (page - 1) * size

        val counted = await db.query("select count(*) as n from threads t" + where.joins + where.sql,
            ...where.params)

        if !counted.ok then return refused(counted)

        val listed = await db.query("select " + ThreadColumns + "
            from threads t join users u on u.id = t.author" + where.joins + where.sql + "
            order by " + order + " limit " + string(size) + " offset " + string(skip),
            ...where.params)

        if !listed.ok then return refused(listed)

        val rows = listed.value.rows
        val ids = map(rows, r -> r.id)
        val labels = await tagsFor(ids)

        if !labels.ok then return labels

        { ok: true,
          value: { rows: map(rows, r -> r with { tags: labels.value[string(r.id)] ?? [] }),
                   total: integer(counted.value.rows[0].n),
                   page: page,
                   size: size } }

    // **The filters are built with `$n` and never with the text itself**, which is what makes a
    // search box safe: the server parses the statement before it is handed a single value, so nothing
    // a person typed can become part of the query.
    conditions(options: object) -> object
        var clauses = []
        var params = []
        var joins = ""

        val q = trim(string(options.q ?? ""))
        val tag = trim(string(options.tag ?? ""))

        if tag != ""
            joins = " join tags g on g.thread = t.id"

            push(params, tag)
            push(clauses, "g.tag = $" + string(len(params)))

        if q != ""
            // **`%` and `_` are `like`'s own wildcards**, so a search for `100%` has to be escaped or
            // it matches everything beginning `100`.
            push(params, "%" + escapedLike(q) + "%")

            val at = "$" + string(len(params))
            val like = " ilike " + at + " escape '\\'"

            push(clauses, "(t.title" + like + " or t.body" + like + ")")

        { sql: if len(clauses) == 0 then "" else " where " + join(clauses, " and "),
          joins: joins,
          params: params }

    // The tags of a set of threads, in one round trip rather than one per row.
    async tagsFor(ids: array)
        if len(ids) == 0 then return { ok: true, value: {} }

        val r = await db.query("select thread, tag from tags where thread = any($1) order by tag", ids)

        if !r.ok then return refused(r)

        var out = {}

        for row in r.value.rows
            val key = string(row.thread)

            if !has(out, key) then out[key] = []

            push(out[key], row.tag)

        { ok: true, value: out }

    async thread(id: integer)
        val r = await db.query("select " + ThreadColumns + " from threads t
            join users u on u.id = t.author where t.id = $1", id)

        if !r.ok then return refused(r)

        val rows = r.value.rows

        if len(rows) == 0 then return { ok: true, value: null }

        val labels = await tagsFor([id])

        if !labels.ok then return labels

        { ok: true, value: rows[0] with { tags: labels.value[string(id)] ?? [] } }

    async addThread(post: object)
        val r = await db.query("insert into threads (title, body, author, photo) values ($1, $2, $3, $4)
            returning id", post.title, post.body, post.author, post.photo)

        if !r.ok then return refused(r)

        val id = r.value.rows[0].id

        for tag in post.tags
            val put = await db.query("insert into tags (thread, tag) values ($1, $2)
                on conflict do nothing", id, tag)

            if !put.ok then return refused(put)

        // **A promise answered from an `async` function is not flattened**, so the awaiting
        // caller would be handed the promise itself rather than the row.
        await thread(id)

    // **The reply and the thread's two counters move in one transaction**, so a reader never sees a
    // reply that the list says is not there. `begin` and `commit` are SQL because they already are;
    // `status()` is how a program asks where it stands.
    async addReply(post: object)
        val opened = await db.query("begin")

        if !opened.ok then return refused(opened)

        val r = await db.query("insert into replies (thread, body, author, photo) values ($1, $2, $3, $4)
            returning id", post.thread, post.body, post.author, post.photo)

        if !r.ok
            await db.query("rollback")

            return refused(r)

        val counted = await db.query("update threads set replies = replies + 1, active = now()
            where id = $1", post.thread)

        if !counted.ok
            await db.query("rollback")

            return refused(counted)

        val done = await db.query("commit")

        if !done.ok then return refused(done)

        await reply(r.value.rows[0].id)

    async reply(id: integer)
        val r = await db.query("select " + ReplyColumns + " from replies r
            join users u on u.id = r.author where r.id = $1", id)

        if !r.ok then return refused(r)

        { ok: true, value: first(r.value.rows) }

    // Every reply of a thread, oldest first, or only those past `after` -- which is what a page that
    // is already showing some of them asks for.
    async replies(id: integer, after)
        val since = if after == null then 0 else after
        val r = await db.query("select " + ReplyColumns + " from replies r
            join users u on u.id = r.author where r.thread = $1 and r.id > $2 order by r.id", id, since)

        if !r.ok then return refused(r)

        { ok: true, value: r.value.rows }

    // **A photo is written after the row that owns it**, because the directory it goes in is named
    // after that row's id. The alternative -- a random name chosen first -- would leave a file behind
    // for every insert that then failed.
    async setThreadPhoto(id: integer, file: string)
        val r = await db.query("update threads set photo = $1 where id = $2", file, id)

        if !r.ok then return refused(r)

        { ok: true, value: r.value.count > 0 }

    async setReplyPhoto(id: integer, file: string)
        val r = await db.query("update replies set photo = $1 where id = $2", file, id)

        if !r.ok then return refused(r)

        { ok: true, value: r.value.count > 0 }

    async deleteReply(id: integer)
        val gone = await db.query("delete from replies where id = $1 returning thread", id)

        if !gone.ok then return refused(gone)

        val rows = gone.value.rows

        if len(rows) == 0 then return { ok: true, value: null }

        val counted = await db.query("update threads set replies = greatest(replies - 1, 0)
            where id = $1", rows[0].thread)

        if !counted.ok then return refused(counted)

        { ok: true, value: rows[0].thread }

    // **`on delete cascade` is what takes the replies and the tags with it**, which is the database
    // holding an invariant rather than this file remembering to.
    async deleteThread(id: integer)
        val r = await db.query("delete from threads where id = $1", id)

        if !r.ok then return refused(r)

        { ok: true, value: r.value.count > 0 }

    // -- what a profile page and a tag list ask ------------------------------------------------------

    async postsOf(id: integer)
        val mine = await db.query("select " + ThreadColumns + " from threads t
            join users u on u.id = t.author where t.author = $1 order by t.made desc limit 50", id)

        if !mine.ok then return refused(mine)

        val said = await db.query("select " + ReplyColumns + ", t.title as thread_title from replies r
            join users u on u.id = r.author join threads t on t.id = r.thread
            where r.author = $1 order by r.made desc limit 50", id)

        if !said.ok then return refused(said)

        { ok: true, value: { threads: mine.value.rows, replies: said.value.rows } }

    async tags()
        val r = await db.query("select tag, count(*) as n from tags group by tag order by n desc, tag limit 40")

        if !r.ok then return refused(r)

        { ok: true, value: map(r.value.rows, row -> { tag: row.tag, count: integer(row.n) }) }

    { ping: ping,
      signUp: signUp,
      signIn: signIn,
      user: user,
      userNamed: userNamed,
      users: users,
      setAvatar: setAvatar,
      threads: threads,
      thread: thread,
      addThread: addThread,
      reply: reply,
      addReply: addReply,
      replies: replies,
      setThreadPhoto: setThreadPhoto,
      setReplyPhoto: setReplyPhoto,
      deleteReply: deleteReply,
      deleteThread: deleteThread,
      postsOf: postsOf,
      tags: tags,
      close: () -> db.close() }

// -- the small things ------------------------------------------------------------------------------

// **A refusal is passed up with its SQLSTATE and nothing is interpreted here.** Which codes mean
// something to a board is `api/routes.sl`'s business; this layer's business is that the code survives
// the trip.
refused(r: object) -> object = { ok: false, error: r.error, code: r.code ?? null }

first(rows: array) = if len(rows) == 0 then null else rows[0]

// **A password column never leaves this file.** The row is read with it because the check needs it,
// and what goes up is the row without it.
withoutPassword(row: object) -> object =
    { id: row.id, name: row.name, role: row.role, avatar: row.avatar, made: row.made }

bounded(n, low: integer, high: integer) -> integer = min(high, max(low, whole(n, low)))

// A whole number out of whatever a query string carried.
//
// **`integer` CONVERTS a number and `number` READS one out of text**, which is the pair to reach for
// here: `integer("3")` faults, and everything in a query string is text.
export whole(said, fallback: integer) -> integer
    val n = if said is string then number(said) else said

    if n is integer then n elif n is real then integer(n) else fallback

escapedLike(s: string) -> string =
    replace(replace(replace(s, "\\", "\\\\"), "%", "\\%"), "_", "\\_")
