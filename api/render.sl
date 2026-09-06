// One page, twice: as markup for a browser, and as the values that markup was made from.
//
// **A GET here answers HTML or JSON and the handler above it does not know which.** That is the whole
// arrangement that makes the board one program: the server works out what a URL means, and then
// either renders `App` through `lath`'s string host into the shell, or answers the same record as
// JSON for the page's own program to render with. `client.slx` asks for the second on every
// navigation, so a link followed in a hydrated page costs the rows and nothing else -- no markup, no
// stylesheet, no second copy of the header.
//
// **The state the browser hydrates against travels in the page**, in a `<script type="application/
// json">`, so the first paint owes nothing to a round trip and the browser adopts markup it was given
// the ingredients for.

import { json } from sluice
import { createElement, createStore, html, mount, Provider } from lath
import { addressIs, withSearch } from lath/router

import { App } from "../app/pages.slx"
import { page, rendersOnServer, titleOf } from "../app/shell.sl"

// The query parameter this program answers JSON to, and the one member of a URL that is about how to
// answer rather than about what is being asked for.
val Format = "format"

// Whether this request wants the values rather than the page.
//
// **Two ways of asking, and the query string is the one that matters.** `Accept` is what a client
// library sends and is read here for it; `?format=json` is what a person with `curl` can type and what
// the page's own program uses, and it is unambiguous where an `Accept` listing both is not.
export wantsJson(req: object) -> boolean
    if (req.query[Format] ?? "") == "json" then return true

    val accept = lower(req.headers["accept"] ?? "")

    contains(accept, "application/json") && !contains(accept, "text/html")

// The address this request is at, as the page will hold it.
//
// **`format` is dropped**, being about the answer rather than about the page: the state a browser
// hydrates against has to name the address a person is on, and `/?format=json` is not an address
// anybody is on.
export addressOf(req: object) -> string
    var query = {}

    for [name, value] in entries(req.query ?? {})
        if name == Format then continue

        query[name] = value

    // **`withSearch` is `lath/router`'s and the page reads the result with `lath/router`'s
    // `useSearch`**, so the address a server writes and the record a component reads out of it are
    // one function apart in each direction rather than two spellings of a query string.
    withSearch(req.path, query)

// `"light"` or `"dark"`, from the request's cookie.
//
// **THE THEME IS A COOKIE AND NOT A QUERY PARAMETER**, which is `mortar` 0.3.2's arrangement: a
// reader's choice belongs to them and not to the page they were on, so it is there again on the very
// next request whichever page they land on. `mortar`'s `Theme` seeds its atom from this value and
// writes the cookie back itself when a reader toggles it -- there is no `/theme` route here.
//
// **Anything that is not `dark` is light**, a cookie being something anybody may set by hand -- which
// is `mortar`'s own rule for the same value, written here in the one place the document is decided.
export themeOf(req: object) -> string =
    if (req.cookies.theme ?? "") == "dark" then "dark" else "light"

// Who is asking, or `null`. **`null` is a page's ordinary case and never a failure** -- a board is
// something to read before it is something to join.
export whoIs(req: object) = req.session.value ?? null

// A page, answered.
//
// `data` is what the route worked out. `status` is what to answer with -- `200` for a page that is
// there, `404` for one that is not, `401` for a sign-in that was refused -- because **the status is
// about the page and not about the rendering**, and a search engine reading a 200 for a missing thread
// is how a board fills an index with nothing.
export answered(req: object, data: object, status: integer = 200) -> object
    val at = addressOf(req)
    val state = { url: at,
                  data: data,
                  user: whoIs(req),
                  csrf: req.csrf ?? "",
                  theme: themeOf(req) }

    if wantsJson(req) then return json(state, status)

    // **`lath/router` is told where the page is before anything renders.**
    addressIs(state.url)

    // **A page the browser builds is sent as an empty container**, which is what `rendersOnServer`
    // decides and `client.slx` reads again on the other side. The state still travels, so the page
    // it mounts knows who is signed in, what the token is and what went wrong with the last post --
    // everything the markup would have carried, minus the markup.
    //
    // **`createStore()` plus `Provider` gives this request its own atom**, so two requests rendered
    // by one process never see each other's theme -- `mortar`'s README says this is load-bearing and
    // not a nicety. `Theme`'s `theme` prop, below in `App`, seeds that store's atom from `state.theme`
    // for this render alone.
    //
    // **`Provider` is found by walking up the render tree from whatever calls `useStore()`, comparing
    // element types** -- so, unlike `App`, it has to be a real element in that tree and not a plain
    // function call: `createElement` is what makes one.
    val markup = if !rendersOnServer(data)
        ""
    else
        val root = App({ nav: { url: state.url, go: null, replace: null },
                         data: data,
                         user: state.user,
                         csrf: state.csrf,
                         theme: state.theme,
                         send: null })

        html(mount(createElement(Provider, { store: createStore() }, [root])))

    { status: status,
      headers: { "Content-Type": "text/html; charset=utf-8" },
      body: page(titleOf(data), state.theme, markup, state) }

// What a POST answers when it worked.
//
// **`303 See Other` and not `200`**, which is what stops a reload posting the same thing again: the
// browser is told to go and GET the page that resulted, so the address bar ends up on a page a
// refresh may safely repeat. A hydrated page is told where to go instead and moves there itself.
export moved(req: object, to) -> object
    if wantsJson(req) then return json({ ok: true, to: to }, 200)

    { status: 303, headers: { Location: to ?? (backTo(req) ?? "/") }, body: "" }

// Where a one-button form said to go back to, if it said anywhere this program could have rendered.
//
// **A destination out of a request is checked and not trusted.** `//elsewhere.example` is another
// origin written the short way and is the shape an open redirect takes; anything that is not a path
// beginning with a single `/` is refused and the board's front page is used instead.
export backTo(req: object)
    val said = (req.body ?? {}).back ?? null

    if said == null then return null

    val to = string(said)

    if to.length > 0 && to[0..<1] == "/" && !startsWith(to, "//") then to else null
