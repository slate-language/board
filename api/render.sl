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
import { html, mount } from lath
import { addressIs, parseSearch, searchOf, withSearch } from lath/router

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

// The query parameter that says which colours to render in.
val Theme = "theme"

// The address this request is at, as the page will hold it.
//
// **`format` is dropped**, being about the answer rather than about the page: the state a browser
// hydrates against has to name the address a person is on, and `/?format=json` is not an address
// anybody is on.
//
// **`theme` IS LEFT EXACTLY AS IT ARRIVED**, and it is `mortar` 0.2.1 that makes that safe: a
// `?theme` that is neither word is the default there, quietly, because the address is whatever a
// person typed or a link carried and a fault over a stranger's spelling would be a 500 nobody
// reading the page could fix. An address the board rewrote would be a second answer to that
// question, kept in step with `mortar`'s by hand.
export addressOf(req: object) -> string
    var query = {}

    for [name, value] in entries(req.query ?? {})
        if name == Format then continue

        query[name] = value

    // **`withSearch` is `lath/router`'s and the page reads the result with `lath/router`'s
    // `useSearch`**, so the address a server writes and the record a component reads out of it are
    // one function apart in each direction rather than two spellings of a query string.
    withSearch(req.path, query)

// `"light"` or `"dark"`, from the address.
//
// **THE THEME IS A QUERY PARAMETER AND NOT A COOKIE**, which is `mortar`'s arrangement and is the one
// worth having: `?theme=dark` is something a person can bookmark and send to somebody else, the
// server can read it off the request and render a dark page the first time, and a reader whose script
// never ran can still change it by following a link. A cookie buys a URL with nothing in it and costs
// a route, a `Set-Cookie` and a page that cannot be linked to in the colour it was read in.
//
// **It is read off the ADDRESS THE PAGE WILL HOLD and not off the request**, which is what makes the
// `data-theme` on `<html>` and the colour `mortar`'s `Theme` renders in one value rather than two
// that agree by inspection: both read the same query string, this one with `lath/router`'s own
// reader and `Theme` with the `useSearch` built on it.
//
// **Anything that is not `dark` is light**, a query string being something anybody may type -- which
// is `mortar`'s own rule for the same value, written here in the one place the document is decided.
export themeOf(url: string) -> string =
    if (parseSearch(searchOf(url))[Theme] ?? "") == "dark" then "dark" else "light"

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
                  theme: themeOf(at) }

    if wantsJson(req) then return json(state, status)

    // **`lath/router` is told where the page is before anything renders.** `router()` does it too,
    // but `Theme` stands ABOVE the router in the tree and reads `?theme` with `useSearch` -- so a
    // page whose theme was decided by whichever expression happened to be evaluated first would be a
    // page that worked by accident.
    addressIs(state.url)

    // **A page the browser builds is sent as an empty container**, which is what `rendersOnServer`
    // decides and `client.slx` reads again on the other side. The state still travels, so the page
    // it mounts knows who is signed in, what the token is and what went wrong with the last post --
    // everything the markup would have carried, minus the markup.
    val markup = if !rendersOnServer(data)
        ""
    else
        html(mount(App({ nav: { url: state.url, go: null, replace: null },
                         data: data,
                         user: state.user,
                         csrf: state.csrf,
                         send: null })))

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

    if len(to) > 0 && to[0..<1] == "/" && !startsWith(to, "//") then to else null
