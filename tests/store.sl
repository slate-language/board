// The board's store, over ordinary arrays. **This is the other implementation of the seam**, and it is
// what lets every route be driven with no database, no socket and nothing to start -- under the
// interpreter and under node alike.
//
// **It declares no tests of its own**, so `slate test tests` walking this directory finds nothing in it
// to run. `tests/routes.sl` is what drives it.
//
// It answers the same results `api/postgres.sl` answers, **including the `23505` a unique index refuses
// a duplicate name with**, which is the one SQLSTATE the application above reads.
//
// **A password is compared and not hashed here.** `slate:password` is Argon2id on a thread pool and is
// not in the JavaScript back end at all, so a suite that ran it would be slow under the interpreter and
// dead under `--js`; what these tests are about is the routes, and the hashing is `tests/postgres.sl`'s
// half of the bargain.

// `board(seed)` -- a store holding whatever `seed` put in it.
//
// `seed` takes `users`, `threads` and `replies`, each an array of the rows the real store answers.
export board(seed: object = {}) -> object
    var users = copyOf(seed.users ?? [])
    var threads = copyOf(seed.threads ?? [])
    var replies = copyOf(seed.replies ?? [])
    var nextUser = 1 + biggest(users)
    var nextThread = 1 + biggest(threads)
    var nextReply = 1 + biggest(replies)
    var well = true

    // What a health check reads. **A store that can be made unwell is what lets the 503 be tested**,
    // and a flag here is exactly what a real one would not have.
    unwell(how: boolean)
        well = !how

    async ping()
        if well then { ok: true, value: true } else { ok: false, error: "no connection", code: null }

    // -- people --------------------------------------------------------------------------------------

    async signUp(name: string, password: string, role: string)
        for u in users
            if u.name == name then return { ok: false, error: "duplicate key", code: "23505" }

        val made = { id: nextUser, name: name, password: password, role: role, avatar: null,
                     made: 1756900000 }

        nextUser = nextUser + 1

        push(users, made)

        { ok: true, value: shown(made) }

    async signIn(name: string, password: string)
        for u in users
            if u.name == name && u.password == password then return { ok: true, value: shown(u) }

        { ok: true, value: null }

    async user(id: integer) = { ok: true, value: shown(byId(users, id)) }

    async userNamed(name: string)
        for u in users
            if u.name == name then return { ok: true, value: shown(u) }

        { ok: true, value: null }

    async users_() = { ok: true, value: map(users, u -> shown(u)) }

    async setAvatar(id: integer, file)
        val u = byId(users, id)

        if u == null then return { ok: true, value: false }

        u.avatar = file

        { ok: true, value: true }

    // -- threads --------------------------------------------------------------------------------------

    async threads_(options: object)
        if !well then return { ok: false, error: "no connection", code: null }

        val size = min(50, max(1, counted(options.size ?? 20, 20)))
        val page = max(1, counted(options.page ?? 1, 1))
        val kept = ordered(matching(threads, options), options.sort ?? "newest")
        val from = (page - 1) * size
        val rows = if from >= len(kept) then [] else kept[from..<min(len(kept), from + size)]

        { ok: true,
          value: { rows: map(rows, t -> whole(users, t)), total: len(kept), page: page, size: size } }

    async thread(id: integer)
        val t = byId(threads, id)

        { ok: true, value: if t == null then null else whole(users, t) }

    async addThread(post: object)
        val made = { id: nextThread, title: post.title, body: post.body, author: post.author,
                     photo: post.photo, replies: 0, made: 1756900000, active: 1756900000,
                     tags: post.tags ?? [] }

        nextThread = nextThread + 1

        push(threads, made)

        { ok: true, value: whole(users, made) }

    async reply(id: integer)
        val r = byId(replies, id)

        { ok: true, value: if r == null then null else saidBy(users, r) }

    async addReply(post: object)
        val t = byId(threads, post.thread)

        if t == null then return { ok: false, error: "foreign key", code: "23503" }

        val made = { id: nextReply, thread: post.thread, body: post.body, author: post.author,
                     photo: post.photo, made: 1756900000 }

        nextReply = nextReply + 1

        push(replies, made)

        t.replies = t.replies + 1

        { ok: true, value: saidBy(users, made) }

    async replies_(id: integer, after)
        val since = if after == null then 0 else after
        var out = []

        for r in replies
            if r.thread == id && r.id > since then push(out, saidBy(users, r))

        { ok: true, value: out }

    async setThreadPhoto(id: integer, file: string)
        val t = byId(threads, id)

        if t == null then return { ok: true, value: false }

        t.photo = file

        { ok: true, value: true }

    async setReplyPhoto(id: integer, file: string)
        val r = byId(replies, id)

        if r == null then return { ok: true, value: false }

        r.photo = file

        { ok: true, value: true }

    async deleteReply(id: integer)
        val r = byId(replies, id)

        if r == null then return { ok: true, value: null }

        val t = byId(threads, r.thread)

        if t != null then t.replies = max(0, t.replies - 1)

        replies = without(replies, id)

        { ok: true, value: r.thread }

    async deleteThread(id: integer)
        if byId(threads, id) == null then return { ok: true, value: false }

        threads = without(threads, id)
        replies = filter(replies, r -> r.thread != id)

        { ok: true, value: true }

    // -- what a profile and a tag list ask ---------------------------------------------------------------

    async postsOf(id: integer)
        var mine = []
        var said = []

        for t in threads
            if t.author == id then push(mine, whole(users, t))

        for r in replies
            if r.author == id
                val t = byId(threads, r.thread)

                push(said, saidBy(users, r) with { thread_title: if t == null then "" else t.title })

        { ok: true, value: { threads: mine, replies: said } }

    async tags()
        var counts = {}

        for t in threads
            for tag in t.tags ?? []
                counts[tag] = (counts[tag] ?? 0) + 1

        var out = []

        for [tag, n] in entries(counts)
            push(out, { tag: tag, count: n })

        { ok: true, value: out }

    { ping: ping,
      signUp: signUp,
      signIn: signIn,
      user: user,
      userNamed: userNamed,
      users: users_,
      setAvatar: setAvatar,
      threads: threads_,
      thread: thread,
      addThread: addThread,
      reply: reply,
      addReply: addReply,
      replies: replies_,
      setThreadPhoto: setThreadPhoto,
      setReplyPhoto: setReplyPhoto,
      deleteReply: deleteReply,
      deleteThread: deleteThread,
      postsOf: postsOf,
      tags: tags,
      unwell: unwell,
      close: () -> null }

// -- the small things ------------------------------------------------------------------------------

// **A password never leaves this file either**, which is the real store's rule kept here so that a
// route reading one would fail the same way in both.
shown(row) = if row == null then null else
    { id: row.id, name: row.name, role: row.role, avatar: row.avatar, made: row.made }

// A thread with its author's name and picture on it, which is what the join in the real store answers.
whole(users: array, t: object) -> object
    val u = byId(users, t.author)

    t with { author_name: if u == null then "?" else u.name,
             author_avatar: if u == null then null else u.avatar,
             tags: t.tags ?? [] }

saidBy(users: array, r: object) -> object
    val u = byId(users, r.author)

    r with { author_name: if u == null then "?" else u.name,
             author_avatar: if u == null then null else u.avatar }

// **`integer` CONVERTS a number and `number` READS one out of text**, and everything in a query
// string is text -- `integer("3")` faults.
counted(said, fallback: integer) -> integer
    val n = if said is string then number(said) else said

    if n is integer then n elif n is real then integer(n) else fallback

byId(rows: array, id)
    for row in rows
        if row.id == id then return row

    null

without(rows: array, id) -> array = filter(rows, r -> r.id != id)

biggest(rows: array) -> integer
    var n = 0

    for row in rows
        if row.id > n then n = row.id

    n

copyOf(rows: array) -> array
    var out = []

    for row in rows
        push(out, row)

    out

// The filters the SQL applies, applied the same way.
matching(rows: array, options: object) -> array
    val tag = lower(trim(string(options.tag ?? "")))
    val text = lower(trim(string(options.q ?? "")))
    var out = []

    for t in rows
        if tag != "" && !contains(t.tags ?? [], tag) then continue
        if text != "" && !said(t, text) then continue

        push(out, t)

    out

said(t: object, text: string) -> boolean = contains(lower(t.title), text) || contains(lower(t.body), text)

// **A comparator answers whether the first value comes BEFORE the second**, which is a boolean and not
// the sign of a subtraction. `docs/library/globals.md` says a number; the machine refuses one.
ordered(rows: array, sort) -> array
    val out = copyOf(rows)

    if sort == "busiest" then out.sort(byReplies)
    elif sort == "active" then out.sort(byActivity)
    else out.sort(byAge)

    out

byReplies(a: object, b: object) -> boolean =
    if a.replies == b.replies then a.made > b.made else a.replies > b.replies

byActivity(a: object, b: object) -> boolean =
    if a.active == b.active then a.id > b.id else a.active > b.active

byAge(a: object, b: object) -> boolean = if a.made == b.made then a.id > b.id else a.made > b.made
