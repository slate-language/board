// `useSearch`, and the two pure functions under it.
//
// **This is the hook `lath` should have**, and it is written here in one file so that it can move
// there unchanged -- `lath/dom` already has `usePath()`, and this is the same idea one level down.
// What keeps it out of `lath/dom` today is that a server has no address bar: it is written over the
// `Nav` context, which every page here is rendered with, so a page the server renders may still ask
// what the search says and offer to change it.

import { createElement, mount, html } from lath

import { Nav } from "../app/context.sl"
import { rendered, useSearch, withSearch } from "../app/search.sl"

// A component that asks for the search and immediately changes it, which is what a sort link does
// when it is clicked. **The hook's whole surface is `[query, set]`**, so this is the whole of it.
Probe(props: object) =
    val search = useSearch()
    val query = search[0]
    val set = search[1]

    set(props.changes)

    val out = <p class="probe">{toJSON(query)}</p>

    out

// What `set` was given, rendered under a `Nav` whose `replace` remembers.
moved(url: string, changes: object) -> object
    var seen = []

    remember(to: string)
        push(seen, to)

    val nav = { url: url, go: remember, replace: remember }
    val markup = html(mount(<Nav.Provider value={nav}><Probe changes={changes}/></Nav.Provider>))

    { seen: seen, markup: markup }

@test
THE_QUERY_IS_A_RECORD_OF_STRINGS_AND_THE_PATH_IS_NOT_IN_IT()
    val out = moved("/?tag=slate&sort=busiest", {})

    assert(contains(out.markup, "\"tag\":\"slate\""))
    assert(contains(out.markup, "\"sort\":\"busiest\""))

@test
SET_MERGES_INTO_WHAT_IS_THERE_AND_KEEPS_THE_PATH()
    val out = moved("/?tag=slate&sort=busiest", { page: 2 })

    assertEq(out.seen, ["/?tag=slate&sort=busiest&page=2"])

@test
A_MEMBER_SET_TO_NULL_IS_REMOVED_WHICH_IS_HOW_A_FILTER_IS_CLEARED()
    val out = moved("/?tag=slate&sort=busiest&page=4", { tag: null, page: null })

    // **The only way to take a key out**, slate having no way to remove one from an object -- and the
    // reading a person wants: choosing the tag they are already filtering by stops filtering.
    assertEq(out.seen, ["/?sort=busiest"])

@test
AN_EMPTY_STRING_IS_REMOVED_TOO_BECAUSE_AN_EMPTY_SEARCH_IS_NO_SEARCH()
    val out = moved("/threads?q=lath", { q: "" })

    assertEq(out.seen, ["/threads"])

@test
SET_REPLACES_RATHER_THAN_PUSHES_SO_A_BACK_BUTTON_IS_NOT_FILLED_WITH_KEYSTROKES()
    var pushed = []
    var replaced = []

    pushing(to: string)
        push(pushed, to)

    replacing(to: string)
        push(replaced, to)

    val nav = { url: "/", go: pushing, replace: replacing }

    html(mount(<Nav.Provider value={nav}><Probe changes={{ sort: "busiest" }}/></Nav.Provider>))

    assertEq(pushed, [])
    assertEq(replaced, ["/?sort=busiest"])

// -- the two functions the hook is built out of --------------------------------------------------------

@test
A_QUERY_IS_RENDERED_WITH_ITS_VALUES_ESCAPED()
    assertEq(rendered({}), "")
    assertEq(rendered({ q: "two words" }), "?q=two%20words")
    assertEq(rendered({ tag: "a&b", page: "2" }), "?tag=a%26b&page=2")

@test
WITH_SEARCH_IS_WHAT_AN_ANCHOR_S_HREF_HAS_TO_BE_SO_A_LINK_WORKS_WITH_NO_SCRIPT()
    assertEq(withSearch("/?tag=slate", { page: 3 }), "/?tag=slate&page=3")
    assertEq(withSearch("/threads/7?a=1#top", { a: 2 }), "/threads/7?a=2")

    // A trailing slash is not a different route, `/` itself excepted -- which is `lath/router`'s rule
    // and comes with `cleanPath`.
    assertEq(withSearch("/people/ada/", { tab: "replies" }), "/people/ada?tab=replies")
