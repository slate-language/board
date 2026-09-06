// The pages, rendered to markup with no document anywhere.
//
// **This is `lath`'s string host, which is what the server uses**, so what is asserted here is the
// markup a browser is actually sent -- and it is the same tree the browser adopts, which is what
// `tests-dom/` measures from the other side.

import { createElement, createStore, mount, html, Provider } from lath
import { addressIs } from lath/router

import { App } from "../app/pages.slx"
import { page, titleOf } from "../app/shell.sl"

// The whole page, as the server renders it.
//
// **`addressIs` first, exactly as `api/render.sl` does it.**
//
// **A FRESH `createStore()` PER CALL, exactly as `api/render.sl` does it too.** `mortar`'s theme atom
// lives in `defaultStore()` where nothing else provides one, and that store is one module-level value
// -- shared by every `shown()` call in this file's process. A test that seeded it dark and left it
// there would leak into the next test's "no `theme` option" case, which is supposed to mean light.
shown(url: string, data: object, options: object = {}) -> string =
    addressIs(url)
    val root = App({ nav: { url: url, go: null, replace: null },
                     data: data,
                     user: options.user ?? null,
                     csrf: options.csrf ?? "tok",
                     theme: options.theme ?? null,
                     send: null })

    html(mount(createElement(Provider, { store: createStore() }, [root])))

val Ada = { id: 1, name: "ada", role: "admin", avatar: null, made: 1756900000 }
val Grace = { id: 2, name: "grace", role: "member", avatar: "avatars/2/face.svg", made: 1756900001 }

thread(over: object = {}) -> object =
    { id: 7, title: "Hello from slate", body: "a first post", photo: null, replies: 2, author: 1,
      author_name: "ada", author_avatar: null, made: 1756900100, active: 1756900300,
      tags: ["slate"] } with over

reply(id: integer, said: string, over: object = {}) -> object =
    { id: id, thread: 7, body: said, photo: null, author: 2, author_name: "grace",
      author_avatar: null, made: 1756900300 } with over

listing(rows: array) -> object =
    { page: "list", threads: { rows: rows, total: rows.length, page: 1, size: 20 },
      tags: [{ tag: "slate", count: 2 }], sort: "newest", tag: "", q: "" }

// -- the router picks the view --------------------------------------------------------------------

@test
ONE_TABLE_OF_ROUTES_ANSWERS_FOR_EVERY_PATH()
    assert(contains(shown("/", listing([thread()])), "class=\"page list\""))
    assert(contains(shown("/new", { page: "compose" }), "class=\"page hint\""))
    assert(contains(shown("/signin", { page: "signin" }), "Sign in</h1>"))
    assert(contains(shown("/signup", { page: "signup" }), "Join the board</h1>"))
    assert(contains(shown("/nowhere", { page: "missing", at: "/nowhere" }), "Nothing at /nowhere"))

@test
A_TRAILING_SLASH_IS_NOT_A_DIFFERENT_ROUTE()
    assert(contains(shown("/signin/", { page: "signin" }), "Sign in</h1>"))

@test
A_QUERY_STRING_DOES_NOT_CHANGE_WHICH_VIEW_ANSWERS()
    assert(contains(shown("/?tag=slate&page=2", listing([])), "class=\"page list\""))

// -- what a page shows while its data is on the way --------------------------------------------------

@test
A_VIEW_WHOSE_DATA_IS_STILL_THE_PREVIOUS_PAGE_S_SAYS_SO_RATHER_THAN_FAULTING()
    // **The browser moves the address before the values arrive**, so for one turn the router is
    // showing a view whose data belongs to the page before it.
    assert(contains(shown("/threads/7", listing([])), "class=\"pending\""))

// -- the list ---------------------------------------------------------------------------------------

@test
A_THREAD_CARD_CARRIES_ITS_LINK_ITS_BYLINE_ITS_TAGS_AND_ITS_COUNT()
    val markup = shown("/", listing([thread()]))

    assert(contains(markup, "href=\"/threads/7\""))
    assert(contains(markup, "class=\"m-who\" href=\"/people/ada\""))
    assert(contains(markup, "<a class=\"m-tag\" href=\"/?tag=slate\">slate</a>"))
    assert(contains(markup, "2 replies"))

@test
AN_EXCERPT_IS_CUT_AND_A_SHORT_POST_IS_NOT()
    val long = repeat("a", 200)
    val markup = shown("/", listing([thread({ body: long })]))

    assert(contains(markup, repeat("a", 160) + "..."))
    assert(!contains(markup, repeat("a", 170)))

@test
THE_SORT_LINKS_ARE_REAL_ANCHORS_CARRYING_THE_WHOLE_ADDRESS()
    val markup = shown("/?tag=slate", listing([]))

    // **So the sort works on a page whose script never ran**, and a cmd-click opens the filtered list
    // in a tab, because what was rendered is an anchor.
    // **The `&` between two parameters is escaped in an attribute**, which is what an HTML
    // serialiser owes: `&sort` would otherwise be read as a character reference.
    assert(contains(markup, "href=\"/?tag=slate&amp;sort=busiest\""))

@test
THE_TAG_BEING_FILTERED_BY_CLEARS_ITSELF_AND_THE_OTHERS_SET_THEMSELVES()
    val on = listing([]) with { tag: "slate" }
    val markup = shown("/?tag=slate", on)

    // **`mortar`'s `Tag` says which one is in force with `aria-current` and nothing else**, so what
    // a page looks like and what a screen reader is told cannot come apart -- there is no `.on` class
    // to forget.
    assert(contains(markup, "<a class=\"m-tag\" href=\"/\" aria-current=\"true\">slate"))

@test
THE_PAGER_COUNTS_PAGES_AND_STOPS_AT_BOTH_ENDS()
    val many = { page: "list", threads: { rows: [], total: 45, page: 1, size: 20 }, tags: [],
                 sort: "newest", tag: "", q: "" }
    val markup = shown("/", many)

    assert(contains(markup, "page 1 of 3"))
    assert(contains(markup, "45 threads"))
    // **`mortar` 0.4.1 stopped rendering a step with nowhere to go at all** -- not inert text, an
    // invisible placeholder that holds the layout slot so the page count stays centred.
    assert(contains(markup, "<span class=\"m-step m-gone\">"))
    assert(contains(markup, "href=\"/?page=2\""))

// -- one thread ---------------------------------------------------------------------------------------

@test
A_REPLY_LIST_IS_KEYED_AND_IN_THE_ORDER_IT_WAS_GIVEN()
    val data = { page: "thread", thread: thread(),
                 replies: [reply(1, "the earlier one"), reply(2, "the later one")] }
    val markup = shown("/threads/7", data)

    assert(contains(markup, "<ul class=\"m-posts\">"))

    // **The order is read out of the LIST and not out of the whole document.** A page now carries the
    // stylesheets of the components it rendered, and a sheet's own prose has ordinary words in it --
    // so an `indexOf` over the whole answer is an `indexOf` over `mortar`'s comments as well.
    val list = markup[indexOf(markup, "<ul class=\"m-posts\">")..]

    assert(indexOf(list, "the earlier one") < indexOf(list, "the later one"))

@test
A_VISITOR_IS_ASKED_TO_SIGN_IN_AND_A_MEMBER_IS_GIVEN_THE_FORM()
    val data = { page: "thread", thread: thread(), replies: [] }
    val visitor = shown("/threads/7", data)
    val member = shown("/threads/7", data, { user: Grace })

    assert(contains(visitor, "to reply."))
    assert(!contains(visitor, "action=\"/threads/7/replies\""))
    assert(contains(member, "action=\"/threads/7/replies\""))

@test
A_MEMBER_MAY_DELETE_THEIR_OWN_REPLY_AND_NOT_SOMEBODY_ELSE_S()
    val mine = { page: "thread", thread: thread(), replies: [reply(1, "grace said this")] }
    val markup = shown("/threads/7", mine, { user: Grace })

    assert(contains(markup, "action=\"/replies/1/delete\""))

    val theirs = { page: "thread", thread: thread(),
                   replies: [reply(1, "ada said this", { author: 1, author_name: "ada" })] }

    assert(!contains(shown("/threads/7", theirs, { user: Grace }), "action=\"/replies/1/delete\""))

@test
AN_ADMINISTRATOR_MAY_DELETE_THE_THREAD_AND_A_MEMBER_MAY_NOT()
    val data = { page: "thread", thread: thread(), replies: [] }

    assert(contains(shown("/threads/7", data, { user: Ada }), "action=\"/threads/7/delete\""))
    assert(!contains(shown("/threads/7", data, { user: Grace }), "action=\"/threads/7/delete\""))

@test
A_BOUNDARY_KEEPS_THE_REST_OF_THE_PAGE_WHEN_THE_THREAD_VIEW_CANNOT_RENDER()
    // **A render fault stays a fault** -- slate's two channels decide that, a component that cannot
    // render being a defect in the program -- and a boundary is a `try` around one subtree. The header
    // and the footer are still there to read while it is fixed.
    val broken = { page: "thread", thread: null, replies: [] }
    val markup = shown("/threads/7", broken)

    assert(contains(markup, "This thread could not be shown."))
    assert(contains(markup, "class=\"m-head\""), "and the rest of the page is still there")
    assert(contains(markup, "class=\"m-foot\""))

// -- photos -----------------------------------------------------------------------------------------

@test
A_PHOTO_IS_AN_IMG_UNDER_UPLOADS_AND_NO_PHOTO_IS_NOTHING()
    val withOne = { page: "thread", thread: thread({ photo: "threads/7/square.svg" }), replies: [] }
    val without = { page: "thread", thread: thread(), replies: [] }

    // **A page asks for `?display`**, which is the copy this board made to be looked at; the bare
    // address is the file somebody posted, and `pictureOf` is the one line that knows the difference.
    assert(contains(shown("/threads/7", withOne), "<img src=\"/uploads/threads/7/square.svg?display\""))
    assert(contains(shown("/threads/7", withOne), "alt=\"Hello from slate\""))
    assert(!contains(shown("/threads/7", without), "<img src=\"/uploads/"))

@test
A_PHOTO_LINKS_THE_FILE_THAT_WAS_POSTED_AND_A_POST_WITH_NONE_LINKS_NOTHING()
    val withOne = { page: "thread", thread: thread({ photo: "threads/7/square.svg" }),
                    replies: [reply(3, "look at this", { photo: "replies/3/wide.svg" }),
                              reply(4, "nothing attached")] }
    val without = { page: "thread", thread: thread(), replies: [] }
    val markup = shown("/threads/7", withOne)

    // **The link is the address without `?display`**, which is the file somebody uploaded rather than
    // the copy this board made to fit a column -- and a reply's photo is offered the same way.
    assert(contains(markup, "<a href=\"/uploads/threads/7/square.svg\">View original</a>"))
    assert(contains(markup, "<a href=\"/uploads/replies/3/wide.svg\">View original</a>"))

    // A post with no photo renders nothing at all rather than a link to nowhere, which is what keeps
    // a hydrating page from adopting a node the server never wrote.
    assert(!contains(shown("/threads/7", without), "View original"))

@test
SOMEBODY_WITH_NO_PICTURE_GETS_THE_FIRST_LETTER_OF_THEIR_NAME()
    val markup = shown("/", listing([thread()]))

    assert(contains(markup, "class=\"m-avatar small\" aria-hidden=\"true\">A<"))

    val pictured = shown("/", listing([thread({ author_avatar: "avatars/2/face.svg" })]))

    assert(contains(pictured, "class=\"m-avatar small\" src=\"/uploads/avatars/2/face.svg?display\""))

// -- the frame ------------------------------------------------------------------------------------------

@test
THE_HEADER_KNOWS_WHO_IS_ASKING()
    val visitor = shown("/", listing([]))
    val member = shown("/", listing([]), { user: Grace })
    val boss = shown("/", listing([]), { user: Ada })

    assert(contains(visitor, "href=\"/signin\""))
    assert(!contains(visitor, "action=\"/signout\""))
    assert(contains(member, "action=\"/signout\""))
    assert(!contains(member, "href=\"/admin\""))
    assert(contains(boss, "href=\"/admin\""))

@test
THE_THEME_COMES_FROM_A_COOKIE_AND_REACHES_EVERY_COMPONENT_ON_ONE_ATTRIBUTE()
    val light = shown("/", listing([]))
    val dark = shown("/", listing([]), { theme: "dark" })

    // **One attribute and not a class per element.** Every colour in `mortar` is a custom property
    // re-declared under `[data-theme="dark"]`, so a page turning over is this and nothing else.
    assert(contains(light, "class=\"mortar board\" data-theme=\"light\""))
    assert(contains(dark, "class=\"mortar board\" data-theme=\"dark\""))

// **`shown()` -- and so `App` and `Theme` -- is handed an ALREADY NORMALISED word or `null`, never a
// stray cookie value.** `Theme`'s `theme` prop faults on anything but `"light"` or `"dark"`, unlike
// the atom it seeds, which `mortar`'s own `resolved()` normalises silently because a reader can reach
// that in ways a prop cannot. It is `api/render.sl`'s `themeOf` that turns a stray cookie word into
// `"light"` before it ever reaches here -- see
// `A_COOKIE_HOLDING_NEITHER_WORD_IS_LIGHT_BECAUSE_A_COOKIE_IS_SOMETHING_ANYBODY_MAY_SET` in
// `tests/routes.sl`, which drives the real HTTP path and pins exactly that.

@test
THE_THEME_CONTROL_IS_TWO_SEGMENTS_SHOWING_BOTH_WORDS_AT_ONCE()
    // **There is no address for this control to carry any more**, so it is a `Segmented` with an
    // `onChoose` and no `href` -- `mortar` writes the cookie itself through `useTheme()`'s own
    // setter. The group carries `aria-label="Theme"`, each segment is a button named "Light" or
    // "Dark", and the one showing is the one marked `aria-current`, unlike the single button this
    // used to be, which named the colour a click went TO and never the one in force.
    val light = shown("/", listing([]))
    val dark = shown("/", listing([]), { theme: "dark" })

    assert(contains(light, "aria-label=\"Theme\""))
    assert(contains(light, "class=\"m-segmented theme\""))
    assert(contains(light, "aria-current=\"true\">Light</button>"))
    assert(contains(light, "class=\"m-seg\">Dark</button>"))
    assert(contains(dark, "aria-current=\"true\">Dark</button>"))
    assert(contains(dark, "class=\"m-seg\">Light</button>"))

@test
EVERY_FORM_CARRIES_THE_TOKEN_AND_WHERE_TO_GO_BACK_TO()
    val markup = shown("/threads/7?tab=x", { page: "thread", thread: thread(), replies: [] },
        { user: Ada, csrf: "a-token" })

    assert(contains(markup, "<input type=\"hidden\" name=\"_csrf\" value=\"a-token\">"))
    assert(contains(markup, "<input type=\"hidden\" name=\"back\" value=\"/threads/7?tab=x\">"))

@test
A_BOOLEAN_ATTRIBUTE_IS_THERE_OR_IS_NOT_THERE_AND_IS_NEVER_FALSE()
    // **`required="false"` is a browser reading a field as required**, so a `false` or a `null` may
    // never be written as an attribute value. `lath` 0.5.1's two hosts agree that neither is an
    // attribute at all, which is HTML's own rule and is what lets a field pass its props straight
    // through -- `required={props.required ?? null}` and nothing assembled first.
    val markup = shown("/signin", { page: "signin" })

    assert(contains(markup, "<input id=\"f-name\" name=\"name\" type=\"text\" required"))
    assert(!contains(markup, "required=\"false\""))
    assert(!contains(markup, "placeholder=\"\""))

    // **A `value` a field has not got is no attribute at all**, which is what makes `mortar`'s
    // `Field` uncontrolled: a browser then keeps what somebody typed rather than being told it back.
    assert(!contains(markup, "name=\"name\" type=\"text\" value"))

// -- the shell ------------------------------------------------------------------------------------------

@test
THE_DOCUMENT_CARRIES_THE_MARKUP_THE_STATE_AND_THE_PROGRAM()
    val data = listing([thread()])
    val state = { url: "/", data: data, user: null, csrf: "tok", theme: "light" }
    val out = page(titleOf(data), "light", shown("/", data), state)

    assert(startsWith(out, "<!doctype html>"))
    assert(contains(out, "<html lang=\"en\" data-theme=\"light\">"))
    assert(contains(out, "<script type=\"application/json\" id=\"board-state\">"))
    assert(contains(out, "<script src=\"/assets/app.js\" defer></script>"))

    // **THERE IS NO `<link rel="stylesheet">` AND NOTHING TO FETCH BEFORE THE FIRST PAINT.** Every
    // sheet a page needs is a file the compiler read into the program and `lath`'s string host wrote
    // in front of the markup, so a page carries a `<style>` for exactly the components it rendered.
    assert(!contains(out, "<link rel=\"stylesheet\""))
    assert(contains(out, "<div id=\"app\"><style data-lath-style>"))
    assert(contains(out, "--m-paper"), "the design tokens came with it")

@test
A_PAGE_CARRIES_THE_SHEETS_OF_THE_COMPONENTS_IT_RENDERED_AND_NO_OTHERS()
    // **This is what one stylesheet per component buys and it is measurable**: a page with no thread
    // list on it ships no thread-list css, and there is no build step deciding which.
    val list = shown("/", listing([thread()]))
    val missing = shown("/nowhere", { page: "missing", at: "/nowhere" })

    assert(contains(list, ".m-thread-card"), "the list rendered cards")
    assert(!contains(missing, ".m-thread-card"), "and the missing page did not")
    assert(contains(missing, ".m-empty"), "but it did render an empty state")

@test
A_LESS_THAN_IN_THE_STATE_IS_ESCAPED_SO_A_POST_CANNOT_END_THE_SCRIPT()
    val data = { page: "thread", thread: thread({ body: "</script><script>alert(1)</script>" }),
                 replies: [] }
    val state = { url: "/threads/7", data: data, user: null, csrf: "tok", theme: "light" }
    val out = page(titleOf(data), "light", shown("/threads/7", data), state)

    assertEq(split(out, "</script>").length, 3)
    assert(contains(out, "\\u003c/script>"))

@test
THE_TITLE_NAMES_THE_PAGE_FIRST()
    assertEq(titleOf(listing([])), "the board")
    assertEq(titleOf({ page: "thread", thread: thread() }), "Hello from slate -- the board")
    assertEq(titleOf({ page: "profile", who: Ada }), "ada -- the board")
    assertEq(titleOf({ page: "missing", at: "/x" }), "Nothing here -- the board")

@test
A_TITLE_IS_ESCAPED_BECAUSE_IT_IS_THE_ONE_STRING_THE_SHELL_INTERPOLATES()
    val data = { page: "thread", thread: thread({ title: "a <b> & \"quotes\"" }), replies: [] }
    val out = page(titleOf(data), "light", "", { url: "/", data: data })

    assert(contains(out, "<title>a &lt;b&gt; &amp; &quot;quotes&quot; -- the board</title>"))

// -- time -----------------------------------------------------------------------------------------------

@test
A_MOMENT_IS_RENDERED_FROM_THE_ROW_AND_NEVER_FROM_THE_CLOCK()
    // **A server rendering *"4 minutes ago"* and a browser adopting it a second later would disagree
    // about the text**, and a hydration mismatch is a fault by design. Two renders of one row have to
    // be one string.
    val data = listing([thread()])

    assertEq(shown("/", data), shown("/", data))
    assert(contains(shown("/", data), "datetime=\"2025-09-03T11:48:20Z\""))
    assert(contains(shown("/", data), ">2025-09-03<"))
