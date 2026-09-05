// Every route, driven with no database and no socket.
//
// **`await app.handle(request(…))` is the whole harness.** A request is a value and a handler is a
// function of it, so what is tested here is the routes, the guards, the failure mapping and the
// markup -- under the interpreter and under node alike, with nothing to start and nothing that can
// flake under load.
//
// The store is `tests/store.sl`'s, over ordinary arrays. What that cannot say anything about is the
// SQL, and `tests/postgres.sl` is that half.

import { response } from sluice
import { exists } from slate:fs
import { files } from slate:http
import { imageShape } from slate:image

import { application } from "../api/routes.sl"
import { sessionStore } from "../api/sessions.sl"
import { nameOf } from "../api/uploads.sl"
import { board } from "./store.sl"
import { bomb, client, decodes, doc, gif, header, picture, program, shows, status, swept, text,
    webp, wide, Gif, GifName, Png, PngName, WebpName } from "./support.sl"

val Secret = "a key this suite made up"

// Two people and two threads, so that ordering, filtering and paging have something to do.
seed() -> object =
    { users: [{ id: 1, name: "ada", password: "supersecret", role: "admin", avatar: null, made: 1756900000 },
              { id: 2, name: "grace", password: "alsosecret", role: "member", avatar: null, made: 1756900001 }],
      threads: [{ id: 1, title: "Hello from slate", body: "a first post about slate", author: 1,
                  photo: null, replies: 1, made: 1756900100, active: 1756900300, tags: ["slate"] },
                { id: 2, title: "About sluice", body: "guards, all the way down", author: 2,
                  photo: null, replies: 0, made: 1756900200, active: 1756900200, tags: ["sluice", "slate"] }],
      replies: [{ id: 1, thread: 1, body: "welcome", author: 2, photo: null, made: 1756900300 }] }

// The board, and something that drives it like a browser.
made(options: object = {}) -> object
    val store = options.store ?? board(seed())
    val sessions = sessionStore({})
    val app = application(store, sessions, options with { secret: Secret, sink: quiet })

    { store: store, sessions: sessions, app: app, at: client(app) }

quiet(r: object) = null

// The name of a picture nobody ever posted, shaped exactly as one this board hands out.
never() -> string = nameOf(toBytes("a photograph nobody took"), "png")

// The same store, always answering and always too late. **Fifty milliseconds against a five
// millisecond deadline**, which is a bound this suite can prove rather than a clock it sleeps
// through.
slow(store: object) -> object
    async late(q: object)
        await sleep(50)

        await store.threads(q)

    store with { threads: late }

// Signed in as somebody the seed knows, with the CSRF cookie already issued.
async signedIn(it: object, name: string, password: string)
    await it.at.get("/")

    await it.at.form("/signin", { name: name, password: password })

// -- the pages ---------------------------------------------------------------------------------------

@test
async THE_FRONT_PAGE_IS_MARKUP_A_READER_CAN_READ_WITH_NO_SCRIPT()
    val it = made()
    val reply = await it.at.get("/")

    assertEq(status(reply), 200)
    assert(contains(string(header(reply, "content-type")), "text/html"))
    assert(shows(reply, "Hello from slate"), "the list names its threads")
    assert(shows(reply, "<form class=\"m-form m-search\" action=\"/\" method=\"get\""),
        "the search box is a real form")
    assert(shows(reply, "href=\"/threads/1\""), "a thread is a real anchor")

@test
async THE_SAME_ROUTE_ANSWERS_THE_VALUES_THE_MARKUP_WAS_MADE_FROM()
    val it = made()
    val said = doc(await it.at.asJson("/"))

    assertEq(said.url, "/")
    assertEq(said.data.page, "list")
    assertEq(said.data.threads.total, 2)
    assertEq(said.user, null)
    assert(said.csrf != "", "the token the next form has to carry travels with the page")

@test
async THE_SORT_THE_FILTER_AND_THE_SEARCH_ARE_READ_OFF_THE_QUERY_STRING()
    val it = made()
    val newest = doc(await it.at.asJson("/?sort=newest"))
    val tagged = doc(await it.at.asJson("/?tag=sluice"))
    val found = doc(await it.at.asJson("/?q=guards"))
    val nonsense = doc(await it.at.asJson("/?sort=whatever"))

    assertEq(newest.data.threads.rows[0].id, 2)
    assertEq(tagged.data.threads.total, 1)
    assertEq(tagged.data.threads.rows[0].title, "About sluice")
    assertEq(found.data.threads.rows[0].id, 2)

    // **A sort key is the one part of a query that cannot be a parameter**, so anything that is not
    // one of the three is the first rather than an error or a statement.
    assertEq(nonsense.data.sort, "newest")

@test
async A_PAGE_PAST_THE_LAST_ONE_IS_EMPTY_AND_STILL_SAYS_HOW_MANY_THERE_ARE()
    val it = made()
    val said = doc(await it.at.asJson("/?size=1&page=7"))

    assertEq(len(said.data.threads.rows), 0)
    assertEq(said.data.threads.total, 2)
    assertEq(said.data.threads.page, 7)

@test
async A_THREAD_SHOWS_ITS_REPLIES_AND_THE_FORM_TO_ADD_ONE()
    val it = made()

    await signedIn(it, "grace", "alsosecret")

    val reply = await it.at.get("/threads/1")

    assertEq(status(reply), 200)
    assert(shows(reply, "welcome"), "the reply that is there is on the page")
    assert(shows(reply, "action=\"/threads/1/replies\""), "and so is the form for the next one")

@test
async A_THREAD_THAT_IS_NOT_THERE_IS_A_404_AND_STILL_A_PAGE()
    val it = made()
    val gone = await it.at.get("/threads/999")
    val nonsense = await it.at.get("/threads/nonsense")
    val nowhere = await it.at.get("/no/such/place")

    assertEq(status(gone), 404)
    assertEq(status(nonsense), 404)
    assertEq(status(nowhere), 404)
    assert(shows(nowhere, "Nothing at /no/such/place"), "a 404 is something a person can read")

// -- the one page the server does not render ---------------------------------------------------------

@test
async THE_COMPOSER_IS_AN_EMPTY_CONTAINER_AND_EVERYTHING_IT_NEEDS_TO_BUILD_ITSELF()
    // **A form with nothing in it yet is markup worth nothing**, so the composer is sent as the
    // document, the state and the script and the browser builds it. Everything else on the board
    // carries rows or a validation error and is rendered here.
    val it = made()

    await signedIn(it, "grace", "alsosecret")

    val reply = await it.at.get("/new")

    assertEq(status(reply), 200)
    assert(shows(reply, "<div id=\"app\"></div>"), "the container is empty")
    assert(!shows(reply, "Start a thread</h1>"), "and the form is not in it")

    // The three things the page it mounts needs, all of them already in the response: who is signed
    // in, the token its post has to carry, and the title in the tab.
    assert(shows(reply, "<title>Start a thread -- the board</title>"))
    assert(shows(reply, "\"page\":\"compose\""), "the state says which page to build")
    assert(shows(reply, "\"name\":\"grace\""), "and who is signed in")
    assert(shows(reply, "\"csrf\":\"" + it.at.token() + "\""), "and what the token is")

@test
async A_REFUSED_POST_TO_A_CLIENT_ONLY_PAGE_STILL_CARRIES_WHY()
    // **The reason travels in the state rather than in the markup**, which is what keeps a `400`
    // readable on a page the server did not render: the browser mounts the composer and `Problem`
    // renders what is in the record.
    val it = made()

    await signedIn(it, "grace", "alsosecret")

    val refused = await it.at.form("/threads", { title: "", body: "", tags: "" })

    assertEq(status(refused), 400)
    assert(shows(refused, "<div id=\"app\"></div>"), "still the empty container")
    assert(shows(refused, "a thread wants a title and something to say"), "and still says why")

@test
async EVERY_OTHER_PAGE_IS_MARKUP_BEFORE_IT_IS_A_SCRIPT()
    // **The control.** Without it the assertion above could be about a shell that is empty for every
    // page, which is a board with no server rendering at all rather than one deliberate exception.
    val it = made()

    for where in ["/", "/threads/1", "/signin", "/signup", "/people/ada", "/no/such/place"]
        val reply = await it.at.get(where)

        assert(!shows(reply, "<div id=\"app\"></div>"), where + " is rendered on the server")

// -- joining, and signing in -----------------------------------------------------------------------

@test
async SIGNING_UP_STARTS_A_SESSION_AND_SENDS_THE_BROWSER_SOMEWHERE_ELSE()
    val it = made()

    await it.at.get("/signup")

    val made_ = await it.at.form("/signup", { name: "hopper", password: "longenough" })

    // **`303 See Other` and not `200`**, which is what stops a reload posting the same thing again.
    assertEq(status(made_), 303)
    assertEq(header(made_, "location"), "/")

    val said = doc(await it.at.asJson("/"))

    assertEq(said.user.name, "hopper")
    assertEq(said.user.role, "member")

@test
async A_NAME_SOMEBODY_ELSE_HAS_IS_A_409()
    val it = made()

    await it.at.get("/signup")

    val again = await it.at.form("/signup", { name: "ada", password: "longenough" })

    assertEq(status(again), 409)
    assertEq(doc(again).status, 409)

@test
async A_FORM_THAT_DOES_NOT_FIT_ITS_DECLARATION_IS_A_400_LISTING_EVERY_REASON()
    val it = made()

    await it.at.get("/signup")

    val bad = await it.at.post("/signup", {})
    val said = doc(bad)

    assertEq(status(bad), 400)
    assertEq(said.title, "Bad Request")
    assertEq(len(said.mismatch), 2)
    assertEq(said.mismatch[0].path, "name")
    assertEq(said.mismatch[1].path, "password")

@test
async A_CHECK_A_SHAPE_CANNOT_MAKE_IS_STILL_A_400()
    val it = made()

    await it.at.get("/signup")

    val short = await it.at.post("/signup", { name: "x", password: "longenough" })

    assertEq(status(short), 400)
    assert(contains(doc(short).detail, "2 and 30"))

@test
async A_NAME_AND_A_PASSWORD_THAT_DO_NOT_GO_TOGETHER_ARE_ONE_ANSWER()
    val it = made()

    await it.at.get("/signin")

    val wrong = await it.at.post("/signin", { name: "ada", password: "notit" })
    val nobody = await it.at.post("/signin", { name: "nobody", password: "notit" })

    assertEq(status(wrong), 401)
    assertEq(status(nobody), 401)

    // **One sentence for both**, because telling them apart hands somebody a way to find out which
    // names exist.
    assertEq(doc(wrong).detail, doc(nobody).detail)

@test
async SIGNING_OUT_ENDS_THE_SESSION()
    val it = made()

    await signedIn(it, "ada", "supersecret")

    assertEq(doc(await it.at.asJson("/")).user.name, "ada")

    await it.at.form("/signout", { back: "/" })

    assertEq(doc(await it.at.asJson("/")).user, null)

// -- the token --------------------------------------------------------------------------------------

@test
async A_FORM_WITH_NO_TOKEN_IS_A_403()
    val it = made()

    await it.at.get("/signin")

    val naked = await it.app.handle({ method: "POST",
                                      path: "/signin",
                                      search: "",
                                      headers: { "content-type": "application/json" },
                                      query: {},
                                      cookies: it.at.cookies(),
                                      params: {},
                                      keepAlive: true,
                                      upgrade: false,
                                      body: toJSON({ name: "ada", password: "supersecret" }) })

    assertEq(status(naked), 403)

@test
async A_FORM_WITH_SOMEBODY_ELSE_S_TOKEN_IS_A_403()
    val it = made()

    await it.at.get("/signin")

    // **The cookie is left alone and the FIELD is forged**, which is the shape the attack has: a form
    // posted from another site carries the cookie -- browsers send those -- and cannot read it.
    val forged = await it.at.sent("POST", "/signin",
        { headers: { "content-type": "application/json" },
          query: { format: "json" },
          body: toJSON({ name: "ada", password: "supersecret", _csrf: "a token from somewhere else" }) })

    assertEq(status(forged), 403)
    assert(contains(doc(forged).detail, "does not match"))

@test
async THE_TOKEN_IS_MINTED_BEFORE_THE_PAGE_IS_RENDERED_SO_THE_FIRST_FORM_CARRIES_IT()
    val it = made()
    val first = await it.at.get("/signin")

    // **This is the difference from a token issued on the way out.** A page rendered before the
    // cookie existed would carry an empty field, and the first form anybody met would be refused.
    assert(shows(first, "name=\"_csrf\" value=\"" + it.at.token() + "\""), "the field holds the cookie")
    assert(it.at.token() != "", "and the cookie was issued with the page that needs it")

// -- posting ------------------------------------------------------------------------------------------

@test
async POSTING_A_THREAD_ASKS_FOR_A_SESSION()
    val it = made()

    await it.at.get("/new")

    val refused = await it.at.form("/threads", { title: "hello", body: "there", tags: "" })

    assertEq(status(refused), 401)

@test
async A_THREAD_IS_POSTED_WITH_ITS_TAGS_AND_APPEARS_ON_THE_LIST()
    val it = made()

    await signedIn(it, "grace", "alsosecret")

    val made_ = await it.at.form("/threads", { title: "lath renders twice",
                                               body: "server and browser",
                                               tags: "Lath, lath, slate,  , one, two, three, four" })

    assertEq(status(made_), 303)
    assertEq(header(made_, "location"), "/threads/3")

    val said = doc(await it.at.asJson("/threads/3"))

    // **Lower case, without repeats, and at most five**, because a tag is a filter and two spellings
    // of one word are two filters that each find half the threads.
    assertEq(said.data.thread.tags, ["lath", "slate", "one", "two", "three"])
    assertEq(said.data.thread.author_name, "grace")

@test
async A_THREAD_WITH_NOTHING_IN_IT_IS_REFUSED()
    val it = made()

    await signedIn(it, "grace", "alsosecret")

    val empty = await it.at.post("/threads", { title: "   ", body: "  ", tags: "" })

    assertEq(status(empty), 400)

@test
async A_REPLY_IS_POSTED_AND_THE_THREAD_COUNTS_IT()
    val it = made()

    await signedIn(it, "ada", "supersecret")

    val said_ = await it.at.form("/threads/1/replies", { body: "and hello back" })

    assertEq(status(said_), 303)

    val said = doc(await it.at.asJson("/threads/1"))

    assertEq(len(said.data.replies), 2)
    assertEq(said.data.replies[1].body, "and hello back")
    assertEq(said.data.thread.replies, 2)

// -- the live thread -------------------------------------------------------------------------------

@test
async A_REPLY_IS_PUBLISHED_TO_WHOEVER_IS_READING_THE_THREAD()
    val it = made()

    await signedIn(it, "ada", "supersecret")

    // **Subscribed before the reply is posted**, which is what a browser reading a thread has done.
    val stream = await it.at.get("/threads/1/events")
    val source = response(stream).body

    assertEq(status(stream), 200)
    assert(contains(string(header(stream, "content-type")), "text/event-stream"))

    await it.at.form("/threads/1/replies", { body: "live from the hub" })

    val piece = await source.next()

    assert(!piece.done, "the stream had something to say")
    assert(contains(piece.value, "event: reply"), "and it says what happened")
    assert(contains(piece.value, "live from the hub"), "and carries the reply itself")

    source.close()

@test
async A_READER_THAT_COMES_BACK_IS_HANDED_WHAT_IT_MISSED()
    val it = made()

    await signedIn(it, "ada", "supersecret")

    await it.at.form("/threads/1/replies", { body: "the one that was missed" })

    // **`Last-Event-ID` is what a browser sends on its own**, and `lastEventId` reads it -- so a
    // client that reconnects is handed what came after that id before anything live.
    val again = await it.app.handle({ method: "GET",
                                      path: "/threads/1/events",
                                      search: "",
                                      headers: { "last-event-id": "0" },
                                      query: {},
                                      cookies: {},
                                      params: {},
                                      keepAlive: true,
                                      upgrade: false })
    val source = response(again).body
    val piece = await source.next()

    assert(contains(piece.value, "the one that was missed"), "the replay carries what was published")
    assert(contains(piece.value, "id: 1"), "and the id a client would come back with")

    source.close()

// -- photos ---------------------------------------------------------------------------------------

@test
async A_PHOTO_IS_KEPT_UNDER_THE_POST_AND_SHOWN_ON_IT()
    val it = made()

    await signedIn(it, "grace", "alsosecret")

    val made_ = await it.at.upload("/threads",
        { title: "a picture", body: "of a square", tags: "art" }, picture("square.png"))

    assertEq(status(made_), 303)

    val said = doc(await it.at.asJson("/threads/3"))

    assertEq(said.data.thread.photo, PngName)

    val page = await it.at.get("/threads/3")

    // **A page asks for `?display`**, which is the copy this board made to be looked at; the bare
    // address is the file somebody posted.
    assert(shows(page, "src=\"/uploads/" + PngName + "?display\""), "and the page shows it")

    await swept(PngName)

@test
async A_PHOTO_IS_NAMED_BY_ITS_CONTENT_AND_NEVER_BY_WHAT_A_CLIENT_SENT()
    val it = made()

    await signedIn(it, "grace", "alsosecret")

    // **The name a client sent never reaches the filesystem at all.** `../../etc/passwd` is the
    // shape every file server has been caught by, and here it is not defended against: the file is
    // named by the digest of its own bytes, so what a client wrote is read and then dropped.
    await it.at.upload("/threads", { title: "climbing out", body: "or trying to", tags: "" },
        picture("../../etc/passwd"))

    val said = doc(await it.at.asJson("/threads/3"))

    assertEq(said.data.thread.photo, PngName)

    // And the same picture posted twice is one file, which is what a content address means.
    await it.at.upload("/threads", { title: "again", body: "the same picture", tags: "" },
        picture("square.png"))

    val again = doc(await it.at.asJson("/threads/4"))

    assertEq(again.data.thread.photo, PngName)

    await swept(PngName)

@test
async A_PHOTO_IS_SERVED_BACK_AS_THE_BYTES_THAT_WERE_POSTED()
    val it = made()

    await signedIn(it, "grace", "alsosecret")

    await it.at.upload("/threads", { title: "a picture", body: "of a square", tags: "" },
        picture("square.png"))

    val got = await it.at.get("/uploads/" + PngName)

    assertEq(status(got), 200)
    assertEq(header(got, "content-type"), "image/png")
    assertEq(response(got).body, Png)

    // **The name is the content**, so the answer may be kept for ever and a client that has it is
    // told so rather than sent it again.
    assertEq(header(got, "cache-control"), "max-age=31536000, immutable")

    val tag = header(got, "etag")
    val back = await it.at.sent("GET", "/uploads/" + PngName, { headers: { "if-none-match": tag } })

    assertEq(status(back), 304)

    await swept(PngName)

@test
async A_NAME_THIS_BOARD_NEVER_HANDED_OUT_IS_A_404_AND_NOT_A_READ()
    val it = made()

    // Both are 404: one is not a name this board could ever have handed out, and the other is
    // exactly the shape of one and belongs to a picture nobody posted.
    assertEq(status(await it.at.get("/uploads/nonsense.png")), 404)
    assertEq(status(await it.at.get("/uploads/" + never())), 404)

@test
async A_PATH_WRITTEN_INTO_A_PHOTO_S_NAME_IS_A_404_HOWEVER_IT_IS_SPELLED()
    // **The three shapes every file server has been caught by**, asked of this one: the escape a
    // router decodes on the way in, the plain one a router may not, and a name cut short by a NUL
    // where a C library reading it would stop. **None of them is a case anybody had to think of** --
    // a name is 43 base64url characters, one dot and one of four extensions, which has no room for a
    // slash, a dot pair or a NUL, so one sentence refuses all three before the disk is touched.
    val it = made()

    for where in ["/uploads/%2e%2e%2fserver.sl", "/uploads/../x", "/uploads/a%00.png"]
        assertEq(status(await it.at.get(where)), 404, where + " is not a photo")

@test
async A_WEBP_IS_A_PICTURE_THIS_BOARD_TAKES()
    // **What a browser re-encoding a photograph before uploading it usually writes**, and the one
    // format of the four that is not `stb_image`'s. It is taken on every host: keeping the original
    // is a write and not a decode.
    val it = made()

    await signedIn(it, "grace", "alsosecret")

    val posted = await it.at.upload("/threads",
        { title: "a webp", body: "eight pixels a side", tags: "" }, webp("shot.webp"))

    assertEq(status(posted), 303)
    assertEq(doc(await it.at.asJson("/threads/3")).data.thread.photo, WebpName)

    val got = await it.at.get("/uploads/" + WebpName)

    assertEq(status(got), 200)
    assertEq(header(got, "content-type"), "image/webp")

    await swept(WebpName)

@test
async A_PICTURE_CLAIMING_MORE_PIXELS_THAN_THIS_BOARD_TAKES_IS_A_413()
    if !decodes() then skip("slate:image is not on the JavaScript host")

    // **Forty-five bytes claiming a hundred and forty-four million pixels.** Every limit on the
    // number of bytes uploaded passes it, because the file really is that small; what refuses it is
    // the header, read before anything is decoded -- so the answer names the size it claimed and no
    // memory was ever asked for.
    val it = made()

    await signedIn(it, "grace", "alsosecret")

    val refused = await it.at.upload("/threads",
        { title: "a large claim", body: "very large", tags: "" }, bomb("huge.png"))

    assertEq(status(refused), 413)
    assert(shows(refused, "12000 by 12000"), "and the answer says what it claimed to be")

    // Nothing at all was written for it.
    assertEq(await exists("./uploads/" + nameOf(bomb("x").bytes, "png")), false)

@test
async THE_DISPLAY_COPY_IS_A_WEBP_AT_THE_WIDTH_OF_THE_COLUMN_AND_THE_ORIGINAL_IS_STILL_THERE()
    if !decodes() then skip("slate:image is not on the JavaScript host")

    // A picture wider than the column it will sit in, which is the ordinary case: a phone's camera
    // writes four thousand pixels across and `--m-measure` is 768 of them.
    val it = made()
    val big = wide(1920, 8)
    val name = nameOf(big, "png")

    await signedIn(it, "grace", "alsosecret")
    await it.at.upload("/threads", { title: "a wide one", body: "much too wide", tags: "" },
        { field: "photo", filename: "wide.png", type: "image/png", bytes: big })

    // **The bare address is the file that was posted, byte for byte**, which is what keeping the
    // original is for: the display copy is smaller and lossy, and the thing somebody actually sent
    // is still there to be asked for.
    val original = await it.at.get("/uploads/" + name)

    assertEq(status(original), 200)
    assertEq(header(original, "content-type"), "image/png")
    assertEq(response(original).body, big)

    // **And `?display` is a different file with a different name**, a WebP at most 1536 across --
    // `mortar`'s own measure, doubled for a retina screen -- with the shape of the original kept.
    val shown_ = await it.at.get("/uploads/" + name + "?display")

    assertEq(status(shown_), 200)
    assertEq(header(shown_, "content-type"), "image/webp")

    val shape = imageShape(response(shown_).body)

    assert(shape.ok, "the display copy is a picture")
    assertEq(shape.value.width, 1536)
    assertEq(shape.value.height, 6)
    assert(len(response(shown_).body) < len(big), "and it is smaller than what was posted")

    await swept(name)

@test
async A_GIF_HAS_NO_DISPLAY_COPY_AND_THE_SAME_ADDRESS_ANSWERS_THE_ORIGINAL()
    // **A GIF keeps its original and nothing else**, `readImage` answering the FIRST FRAME of one:
    // a derived copy of an animation is a still of it, and a board that quietly did that to a
    // reaction GIF has thrown away what was posted.
    //
    // **So `?display` falls back**, which is what lets a page ask for the copy to look at without
    // knowing whether there is one -- and is the same line that carries a host with no image library.
    val it = made()

    await signedIn(it, "grace", "alsosecret")
    await it.at.upload("/threads", { title: "a reaction", body: "moving, in principle", tags: "" },
        gif("wave.gif"))

    val got = await it.at.get("/uploads/" + GifName + "?display")

    assertEq(status(got), 200)
    assertEq(header(got, "content-type"), "image/gif")
    assertEq(response(got).body, Gif)

    await swept(GifName)

@test
async AN_AVATAR_S_DISPLAY_COPY_IS_THE_FIXED_SQUARE_WHATEVER_SHAPE_WAS_SENT()
    if !decodes() then skip("slate:image is not on the JavaScript host")

    // **`.m-avatar` is a circle with `object-fit: cover` on it**, so what is stored is the square
    // that fills it: 128 pixels, which is `mortar`'s `large` at 4rem doubled for a retina screen.
    // A picture 240 times wider than it is tall still comes back square.
    val it = made()
    val banner = wide(1920, 8)
    val name = nameOf(banner, "png")

    await signedIn(it, "grace", "alsosecret")

    val put = await it.at.upload("/profile/avatar", {},
        { field: "photo", filename: "me.png", type: "image/png", bytes: banner })

    assertEq(status(put), 303)

    // **The row keeps the ORIGINAL's name**, exactly as a post's photo does; what differs is only
    // the copy behind `?display`.
    assertEq(doc(await it.at.asJson("/people/grace")).data.who.avatar, name)

    val face = await it.at.get("/uploads/" + name + "?display")
    val shape = imageShape(response(face).body)

    assertEq(header(face, "content-type"), "image/webp")
    assertEq(shape.value.width, 128)
    assertEq(shape.value.height, 128)

    await swept(name)

@test
async SOMETHING_THAT_IS_NOT_AN_IMAGE_IS_A_415_WHATEVER_IT_SAYS_IT_IS()
    val it = made()

    await signedIn(it, "grace", "alsosecret")

    // **It is labelled `image/png` and it is a shell script**, which is exactly what the header is
    // worth: the first bytes are what decide.
    val refused = await it.at.upload("/threads", { title: "a program", body: "not a picture", tags: "" },
        program("innocent.png"))

    assertEq(status(refused), 415)

    // **A guard refuses with a problem document and a handler answers a page**, which is the line
    // this board draws and it is `sluice`'s own: the guard is the same answer for a browser and for
    // a client library, and what it names is the part it turned down.
    val said = doc(refused)

    assertEq(said.title, "Unsupported Media Type")
    assertEq(said.field, "photo")
    assertEq(said.filename, "innocent.png")

@test
async A_REFUSED_UPLOAD_IS_STILL_A_PROBLEM_DOCUMENT_AND_ITS_TYPE_IS_THE_PROBLEM_S()
    // **RFC 9457's `type` is the PROBLEM's type, a URI, and `about:blank` where there is none.**
    // The media type the client claimed is a different thing and `sluice` 0.4.1 calls it a different
    // thing: it comes back as `mediaType`, and `type` says what every problem document's `type` says.
    val it = made()

    await signedIn(it, "grace", "alsosecret")

    val refused = await it.at.upload("/threads", { title: "a program", body: "not a picture", tags: "" },
        program("innocent.png"))

    assertEq(doc(refused).type, "about:blank")
    assertEq(doc(refused).mediaType, "image/png")

@test
async A_PHOTO_OVER_THE_LIMIT_IS_A_413()
    val it = made({ photoLimit: 64 })

    await signedIn(it, "grace", "alsosecret")

    val refused = await it.at.upload("/threads", { title: "too big", body: "much too big", tags: "" },
        picture("big.png"))

    assertEq(status(refused), 413)

    // **The size is checked before anything is parsed**, which is the only order that bounds the
    // work a stranger can ask for -- and the document says both numbers.
    assertEq(doc(refused).limit, 64)
    assert(doc(refused).size > 64)

// -- taking things away -------------------------------------------------------------------------------

@test
async A_MEMBER_MAY_DELETE_THEIR_OWN_REPLY_AND_NOT_SOMEBODY_ELSE_S()
    val it = made()

    await signedIn(it, "grace", "alsosecret")

    val mine = await it.at.form("/replies/1/delete", { back: "/threads/1" })

    assertEq(status(mine), 303)
    assertEq(len(doc(await it.at.asJson("/threads/1")).data.replies), 0)

    await it.at.form("/threads/1/replies", { body: "grace again" })
    await it.at.form("/signout", { back: "/" })
    await it.at.form("/signin", { name: "ada", password: "supersecret" })

    // An administrator may delete anybody's.
    assertEq(status(await it.at.form("/replies/2/delete", { back: "/threads/1" })), 303)

@test
async DELETING_A_THREAD_IS_AN_ADMINISTRATOR_S()
    val it = made()

    await signedIn(it, "grace", "alsosecret")

    assertEq(status(await it.at.form("/threads/1/delete", { back: "/" })), 403)

    await it.at.form("/signout", { back: "/" })
    await it.at.form("/signin", { name: "ada", password: "supersecret" })

    assertEq(status(await it.at.form("/threads/1/delete", { back: "/" })), 303)
    assertEq(doc(await it.at.asJson("/")).data.threads.total, 1)

// -- the admin page -----------------------------------------------------------------------------------

@test
async THE_ADMIN_PAGE_IS_A_403_PAGE_FOR_EVERYBODY_ELSE()
    val it = made()
    val visitor = await it.at.get("/admin")

    assertEq(status(visitor), 403)
    assert(shows(visitor, "for administrators"), "and says so in words")

    await signedIn(it, "ada", "supersecret")

    assertEq(status(await it.at.get("/admin")), 200)

@test
async AN_ADMINISTRATOR_SEES_WHO_IS_SIGNED_IN_AND_CAN_END_IT()
    val it = made()
    val other = made()

    await signedIn(it, "ada", "supersecret")

    val said = doc(await it.at.asJson("/admin"))

    assertEq(len(said.data.users), 2)
    assertEq(len(said.data.sessions), 1)
    assertEq(said.data.sessions[0].name, "ada")

    // **Revoking is the thing a signed cookie cannot do at all**, and it is the whole argument for a
    // store: the entry is deleted, and the very next request from that browser is nobody.
    val gone = await it.at.form("/admin/sessions/" + said.data.sessions[0].id + "/revoke", { back: "/admin" })

    assertEq(status(gone), 303)
    assertEq(doc(await it.at.asJson("/")).user, null)

// -- the theme ------------------------------------------------------------------------------------------

@test
async THE_THEME_IS_IN_THE_ADDRESS_AND_THE_SERVER_ALREADY_KNOWS_IT_WHEN_IT_RENDERS()
    val it = made()
    val first = await it.at.get("/")

    assert(shows(first, "data-theme=\"light\""))

    // **No form, no cookie and no second request**: the choice is a link, so this is the same GET
    // anybody could have typed or bookmarked.
    val dark = await it.at.get("/?theme=dark")

    assert(shows(dark, "class=\"mortar board\" data-theme=\"dark\""),
        "and the markup carries it, so nothing flashes white")
    assert(shows(dark, "<html lang=\"en\" data-theme=\"dark\">"), "on the document too")

    // **The control is two real anchors**, which is what makes the theme something a reader with no
    // script running can change.
    assert(shows(dark, "<a class=\"m-seg\" href=\"/\">Light</a>"))

@test
async ANYTHING_THAT_IS_NOT_dark_IS_LIGHT_BECAUSE_A_QUERY_IS_SOMETHING_ANYBODY_MAY_TYPE()
    val it = made()

    // **Nothing here normalises the address any more**: `mortar` 0.2.1's `Theme` reads a word it does
    // not know as the default and says nothing, so the board serves a light page for a spelling a
    // stranger chose rather than a 500 -- and the word stays in the address it was typed into.
    val said = await it.at.get("/?theme=chartreuse")

    assert(shows(said, "data-theme=\"light\""))
    assert(shows(said, "\"url\":\"/?theme=chartreuse\""),
        "and the page hydrates against the address a person is really on")

// -- where a form says to go back to ------------------------------------------------------------------

@test
async A_DESTINATION_OUT_OF_A_REQUEST_IS_CHECKED_AND_NOT_TRUSTED()
    val it = made()

    await signedIn(it, "grace", "alsosecret")

    val away = await it.at.form("/signout", { back: "//elsewhere.example/steal" })

    // `//elsewhere.example` is another origin written the short way, which is the shape an open
    // redirect takes.
    assertEq(header(away, "location"), "/")

// -- staying up -----------------------------------------------------------------------------------------

@test
async EVERY_ANSWER_IS_NAMED_AND_AN_ID_A_CLIENT_ALREADY_HAS_IS_KEPT()
    val it = made()

    // **The id is on the answer and not only in the log**, which is what lets somebody looking at a
    // page and somebody looking at the log line be talking about the same request.
    assert(header(await it.at.get("/"), "X-Request-Id") != null, "every answer is named")

    val traced = await it.at.sent("GET", "/", { headers: { "x-request-id": "cafe-1234" } })

    assertEq(header(traced, "X-Request-Id"), "cafe-1234")

@test
async A_REQUEST_THAT_OUTRUNS_ITS_DEADLINE_IS_ANSWERED_AND_NOT_LEFT_HANGING()
    // **503 and not 504**, which is RFC 9110's own line: 504 is for a server acting as a gateway,
    // and a board waiting on its own database is not one.
    val it = made({ deadline: 5, store: slow(board(seed())) })
    val late = await it.at.asJson("/")

    assertEq(status(late), 503)
    assertEq(doc(late).title, "Service Unavailable")

@test
async A_DRAINING_BOARD_ANSWERS_503_TO_EVERYTHING_ITS_OWN_HEALTH_CHECK_INCLUDED()
    val it = made()

    assertEq(status(await it.at.get("/health")), 200)

    // **This is what `SIGTERM` does first**: stop taking new requests, then let what is in hand
    // finish, then let go of the socket. A load balancer reading the health check is told to send
    // the next request elsewhere, which is the whole point of answering rather than closing.
    it.app.stop()

    assertEq(status(await it.at.get("/")), 503)
    assertEq(status(await it.at.get("/health")), 503)
    assertEq(status(await it.at.post("/signin", { name: "ada", password: "supersecret" })), 503)

// Whether this host can serve a file at all, asked by TRYING rather than by naming a back end.
//
// **`slate:http`'s `files(root)` faults under `--js`** -- *"`epochMillis` is not something undefined
// can do"*, from the `mtime` a `stat` answers, the calendar half of `slate:time` being owed on that
// back end. A slate program has no name for which host it is running on, deliberately, so the
// question goes to the thing itself. Reported to the compiler 2026-09-05.
async canServe() -> boolean
    val serve = files("./public", {})

    try
        await serve({ method: "GET", path: "/assets/app.js", params: { rest: "app.js" },
                      headers: {}, query: {}, cookies: {} })

        return true
    catch e
        return false

@test
async THE_BROWSER_PROGRAM_IS_SERVED_OFF_THE_DISK_AND_NOTHING_ELSE_IS()
    if !(await canServe()) then skip("slate:http's files() faults on this host: a stat has no mtime")
    if !(await exists("./public/app.js"))
        skip("the browser program has not been built: slate js client.slx -o public/app.js")

    val it = made()
    val js = await it.at.get("/assets/app.js")

    assertEq(status(js), 200)

    // **A file off the disk arrives as BYTES**, which is what `slate:http`'s `files` answers for
    // everything it serves -- a program and a font are read the same way, and only the reader knows
    // which is text.
    val body = response(js).body
    val said = if body is string then body else fromBytes(body).value

    assert(contains(said, "board-state"), "the board's own browser program")

    // **THERE IS NO STYLESHEET TO SERVE ANY MORE.** Every sheet on a page is a file the compiler read
    // into the program and `lath`'s string host wrote into the markup, so this route answers the
    // browser program and nothing else.
    assertEq(status(await it.at.get("/assets/style.css")), 404)

    // **A files route serves what is under its root and nothing above it.**
    assertEq(status(await it.at.get("/assets/nothing.css")), 404)

@test
async THE_HEALTH_CHECK_ASKS_THE_STORE_AND_NOT_A_FLAG_IN_THIS_PROCESS()
    val it = made()

    assertEq(status(await it.at.get("/health")), 200)

    it.store.unwell(true)

    val ill = await it.at.get("/health")

    assertEq(status(ill), 503)
    assert(contains(doc(ill).reasons[0], "not answering"), "and says which of the things it is")

@test
async A_STORE_THAT_IS_DOWN_IS_A_503_PROBLEM_DOCUMENT_AND_NOT_A_FAULT()
    val it = made()

    it.store.unwell(true)

    val ill = await it.at.asJson("/")

    assertEq(status(ill), 503)
    assertEq(doc(ill).title, "Service Unavailable")

@test
async TOO_MANY_WRITES_A_MINUTE_ARE_429_WITH_A_RETRY_AFTER()
    val it = made({ postLimit: 2 })

    await it.at.get("/signin")
    await it.at.post("/signin", { name: "ada", password: "wrong" })
    await it.at.post("/signin", { name: "ada", password: "wrong" })

    val over = await it.at.post("/signin", { name: "ada", password: "wrong" })

    assertEq(status(over), 429)
    assert(header(over, "retry-after") != null, "and says how long to wait")
    assertEq(string(header(over, "x-ratelimit-limit")), "2")

// -- the JSON API ----------------------------------------------------------------------------------------

@test
async THE_JSON_API_ANSWERS_ROWS_AND_PROBLEM_DOCUMENTS()
    val it = made()
    val listed = await it.at.get("/api/threads")

    assertEq(status(listed), 200)
    assertEq(doc(listed).total, 2)

    val one = await it.at.get("/api/threads/1")

    assertEq(len(doc(one).replies), 1)

    val gone = await it.at.get("/api/threads/999")

    assertEq(status(gone), 404)
    assertEq(doc(gone).title, "Not Found")
    assert(contains(string(header(gone, "content-type")), "application/problem+json"))

@test
async THE_POLL_A_PAGE_MAKES_ASKS_ONLY_FOR_WHAT_IT_HAS_NOT_SEEN()
    val it = made()

    await signedIn(it, "ada", "supersecret")
    await it.at.form("/threads/1/replies", { body: "the new one" })

    val fresh = doc(await it.at.get("/api/threads/1/replies?after=1"))

    assertEq(len(fresh.replies), 1)
    assertEq(fresh.replies[0].body, "the new one")

@test
async THE_JSON_API_TAKES_ITS_TOKEN_IN_A_HEADER_BECAUSE_A_CLIENT_LIBRARY_CAN_SET_ONE()
    val it = made()

    await signedIn(it, "ada", "supersecret")

    val made_ = await it.app.handle({ method: "POST",
                                      path: "/api/threads",
                                      search: "",
                                      headers: { "content-type": "application/json",
                                                 "x-csrf-token": it.at.token() },
                                      query: {},
                                      cookies: it.at.cookies(),
                                      params: {},
                                      keepAlive: true,
                                      upgrade: false,
                                      body: toJSON({ title: "over the api", body: "with a header",
                                                     tags: "api" }) })

    assertEq(status(made_), 201)
    assertEq(doc(made_).title, "over the api")

// -- what a person sees while a page is on the way ---------------------------------------------------------

@test
async THE_PAGE_CARRIES_THE_STATE_THE_BROWSER_HYDRATES_AGAINST()
    val it = made()
    val page = await it.at.get("/?tag=slate")

    assert(shows(page, "<script type=\"application/json\" id=\"board-state\">"))
    assert(shows(page, "<script src=\"/assets/app.js\" defer>"))

    // **A `<` inside the state is written as an escape**, which is the one thing that can end a
    // `<script>` early: a post holding `</script>` in its text would close the element.
    assert(!contains(text(page), "\"body\":\"<"), "nothing in the state carries a raw <")
