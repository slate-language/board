// The four values every page reads and nothing threads through as a prop.
//
// **A context is a field of itself** -- `<Session.Provider value={…}>` is an ordinary field selection
// inside a tag -- so these are values rather than components, and a page reads one with
// `useContext(Session)` wherever it stands.
//
// **This file imports nothing that needs a host**, which is what lets the same page components render
// to markup on the server and into the document in a browser. What differs between the two is the
// value each provider is handed, and nothing else.

import { createContext } from lath

// What a server's `go` and `replace` are. **A named function and not a lambda**, a lambda's one-line
// body being an expression and `null` being what this answers.
unmoved(url: string) = null

// Who is asking, and the CSRF token every form of theirs carries.
//
// `user` is `null` for a visitor, which is a page's ordinary case and never a fault.
export val Session = createContext({ user: null, csrf: "" })

// `"light"` or `"dark"`. It rides in a cookie so that a page rendered by the server already has it and
// nothing flashes white on the way in.
export val Theme = createContext("light")

// What the server worked out for this URL: the rows, the counts and the failures of one page. A view
// reads it with `useContext(Board)` rather than being handed it, so a route's `view` stays the one
// line the router's own documentation shows.
export val Board = createContext({ page: "missing", at: "/" })

// The address, and the two ways of moving it.
//
// **This is the seam that keeps every page component host-free.** `lath/router` is handed a path and
// never reads one; this carries the path and the two functions that write it, so a page may move the
// address without importing `slate:dom`. On the server both functions do nothing -- there is no
// address bar to write -- and `client.slx` fills them in.
//
//     go(url)       a new entry in the history: following a link
//     replace(url)  the same entry, rewritten: changing a sort, a filter or a page number
export val Nav = createContext({ url: "/", go: unmoved, replace: unmoved })

// How a form reaches the server without the page being thrown away and built again.
//
// **`send` is `null` on a server and on a page whose script has not run**, which is exactly what makes
// the forms work either way: a submit handler that finds no sender does not call `prevent`, so the
// browser posts the form itself and answers with the next page. Where `client.slx` has installed one,
// the same handler sends the fields, is given the outcome, and the page moves without a reload.
//
//     send(action, fields)   a promise of { ok, to } or { ok: false, status, detail, mismatch }
export val Post = createContext({ send: null })
