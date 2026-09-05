// `useSearch()` -- the query string as state.
//
//     val [query, set] = useSearch()
//
//     set({ sort: "busiest", page: null })
//
// **This is one file so that it can move into `lath` unchanged**, which is where it belongs: `lath/dom`
// already has `usePath()`, and this is the same idea one level down -- the part of the address after
// the `?`, read as a record and written back without a reload.
//
// **It is written over the `Nav` context and not over `slate:dom` on purpose.** A server has no address
// bar, so a hook that reached for `replacePath` could not be called by a page the server renders --
// and every page here is rendered twice. `lath` would write it over `location()` and `replacePath`
// directly and offer the context as the seam, which is what `navigateWith` already is.
//
// **`set` REPLACES rather than pushes.** Choosing a sort, a tag or a page number is not somewhere a
// person navigated *to*; a back button filled with every keystroke of a search box is the thing this
// avoids. A `Link` is what pushes.
//
// **A member set to `null` or `""` is REMOVED**, which is what makes `set({ tag: null })` read as
// *stop filtering* -- and it is also the only way to take a key out, slate having no way to remove one
// from an object.

import { useContext } from lath
import { cleanPath, parseSearch, searchOf } from lath/router
import { encodeComponent } from slate:url

import { Nav } from "./context.sl"

// `[query, set]`. `query` is an object of strings -- `lath/router`'s own reading of the search, so a
// repeated name is the last one and a bare `?debug` is present and empty.
export useSearch() -> array =
    val nav = useContext(Nav)
    val query = parseSearch(searchOf(nav.url))

    set(changes: object)
        nav.replace(cleanPath(nav.url) + rendered(merged(query, changes)))

    [query, set]

// What `rendered` is given: the members of `was` that survive, then the ones `changes` names.
merged(was: object, changes: object) -> object
    var out = {}

    for [name, value] in entries(was)
        if !has(changes, name) then out[name] = value

    for [name, value] in entries(changes)
        if value != null && string(value) != "" then out[name] = string(value)

    out

// `?a=1&b=two+words`, or nothing at all where there is nothing to say. **`encodeComponent` is
// `slate:url`'s**, which is the module `lath/router` already reaches for -- importing `slate:http` for
// it would put a file server and an HTTP/2 speaker into a page.
export rendered(query: object) -> string
    var parts = []

    for [name, value] in entries(query)
        push(parts, encodeComponent(name) + "=" + encodeComponent(string(value)))

    if len(parts) == 0 then "" else "?" + join(parts, "&")

// The same query with one member changed, as a URL -- which is what an `<a href>` needs, a link having
// to work on a page whose script has not run.
export withSearch(url: string, changes: object) -> string =
    cleanPath(url) + rendered(merged(parseSearch(searchOf(url)), changes))
