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
import { addressIs } from lath/router

import { App } from "../app/pages.slx"
import { page, titleOf } from "../app/shell.sl"
import { rendered as searchOf } from "../app/search.sl"

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
// **`theme` IS NORMALISED HERE AND THAT IS THE SERVER'S JOB.** `mortar`'s `Theme` refuses a `?theme`
// that is neither word -- deliberately, so that a program writing a wrong one is told -- but a query
// string is something anybody may type, so a value out of a request is not a program's mistake and
// may not be a `500`. Anything that is not `dark` is dropped, which is also the canonical spelling of
// light: the default never rides in an address the board rendered.
export addressOf(req: object) -> string
    var query = {}

    for [name, value] in entries(req.query ?? {})
        if name == Format then continue

        if name == Theme
            if value == "dark" then query[name] = "dark"

            continue

        query[name] = value

    req.path + searchOf(query)

// `"light"` or `"dark"`, from the address.
//
// **THE THEME IS A QUERY PARAMETER AND NOT A COOKIE**, which is `mortar`'s arrangement and is the one
// worth having: `?theme=dark` is something a person can bookmark and send to somebody else, the
// server can read it off the request and render a dark page the first time, and a reader whose script
// never ran can still change it by following a link. A cookie buys a URL with nothing in it and costs
// a route, a `Set-Cookie` and a page that cannot be linked to in the colour it was read in.
//
// **Anything that is not `dark` is light**, a query string being something anybody may type.
export themeOf(req: object) -> string = if (req.query[Theme] ?? "") == "dark" then "dark" else "light"

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
    val state = { url: addressOf(req),
                  data: data,
                  user: whoIs(req),
                  csrf: req.csrf ?? "",
                  theme: themeOf(req) }

    if wantsJson(req) then return json(state, status)

    // **`lath/router` is told where the page is before anything renders.** `router()` does it too,
    // but `Theme` stands ABOVE the router in the tree and reads `?theme` with `useSearch` -- so a
    // page whose theme was decided by whichever expression happened to be evaluated first would be a
    // page that worked by accident.
    addressIs(state.url)

    val markup = html(mount(App({ nav: { url: state.url, go: null, replace: null },
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
