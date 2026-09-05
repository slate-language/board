// The query string, as this board reads it and as it writes it back.
//
// **The hook is `lath/router`'s `useSearch` and this file used to be the board's own.** What is
// asserted here is therefore not the hook -- `lath` has its own tests for that -- but the two things
// the board depends on and would notice losing: that a control changing one member of the query
// keeps the rest, and that changing one REWRITES the address rather than pushing it.
//
// **`set` takes the WHOLE query**, so the merging that used to live under the hook now happens where
// a control writes: `set(query with { sort: v, page: null })`. That is the whole of the difference
// and it is the better arrangement -- the expression that says what changes is the same one the
// anchor's `href` is built from, so a link and a click cannot drift apart.

import { createElement, mount, html } from lath
import { addressIs, navigateWith, useSearch, withSearch } from lath/router

// A component that asks for the search and immediately changes it, which is what a sort link does
// when it is clicked. **The hook's whole surface is `[query, set]`**, so this is the whole of it.
Probe(props: object) =
    val search = useSearch()
    val query = search[0]
    val set = search[1]

    set(props.write(query))

    val out = <p class="probe">{toJSON(query)}</p>

    out

// What `set` was given, rendered with a `navigateWith` that remembers instead of moving.
//
// **`addressIs` is how a render with no address bar is told where it is**, which is exactly what
// `api/render.sl` does before it renders a page: on a server `useSearch` reads the address this
// module was handed, and in a browser `lath/dom`'s `usePath` is underneath it instead.
moved(url: string, write: function) -> object =
    var pushed = []
    var replaced = []

    remember(to: string, opts = null)
        if opts != null && opts.push == true then push(pushed, to) else push(replaced, to)

        null

    addressIs(url)
    navigateWith(remember)

    val markup = html(mount(<Probe write={write}/>))

    navigateWith(null)

    { seen: concat(pushed, replaced), pushed: pushed, replaced: replaced, markup: markup }

@test
THE_QUERY_IS_A_RECORD_OF_STRINGS_AND_THE_PATH_IS_NOT_IN_IT()
    val out = moved("/?tag=slate&sort=busiest", (q) -> q)

    assert(contains(out.markup, "\"tag\":\"slate\""))
    assert(contains(out.markup, "\"sort\":\"busiest\""))

@test
A_CONTROL_HANDS_BACK_THE_QUERY_IT_HAS_WITH_ONE_MEMBER_CHANGED_AND_THE_PATH_IS_KEPT()
    val out = moved("/?tag=slate&sort=busiest", (q) -> q with { page: 2 })

    assertEq(out.seen, ["/?tag=slate&sort=busiest&page=2"])

@test
A_MEMBER_SET_TO_NULL_IS_REMOVED_WHICH_IS_HOW_A_FILTER_IS_CLEARED()
    val out = moved("/?tag=slate&sort=busiest&page=4", (q) -> q with { tag: null, page: null })

    // **`null` is how a name comes off an address**, and the reading a person wants: choosing the tag
    // they are already filtering by stops filtering.
    assertEq(out.seen, ["/?sort=busiest"])

@test
AN_EMPTY_SEARCH_IS_NO_SEARCH_AND_THE_NAME_GOES_WITH_IT()
    // **`without` and not `q: ""`**, which is the one place `lath`'s rule differs from the helper
    // this file used to test: an empty string is a value somebody chose and is written as `?q=`, and
    // `null` is the absence. Clearing a search box means the second.
    val out = moved("/threads?q=lath", (q) -> without(q, "q"))

    assertEq(out.seen, ["/threads"])

@test
SET_REPLACES_RATHER_THAN_PUSHES_SO_A_BACK_BUTTON_IS_NOT_FILLED_WITH_KEYSTROKES()
    val out = moved("/", (q) -> q with { sort: "busiest" })

    assertEq(out.pushed, [])
    assertEq(out.replaced, ["/?sort=busiest"])

// -- the same query, as the `href` an anchor carries ----------------------------------------------------

@test
WITH_SEARCH_IS_WHAT_AN_ANCHOR_S_HREF_HAS_TO_BE_SO_A_LINK_WORKS_WITH_NO_SCRIPT()
    assertEq(withSearch("/?tag=slate", { tag: "slate", page: 3 }), "/?tag=slate&page=3")

    // **The fragment and the path's own spelling survive**, which is `lath`'s rule and the right one:
    // a person who is a third of the way down a thread and changes a filter is still where they were,
    // and a query is not allowed to move a page from `/people/ada/` to `/people/ada`.
    assertEq(withSearch("/threads/7?a=1#top", { a: 2 }), "/threads/7?a=2#top")
    assertEq(withSearch("/people/ada/", { tab: "replies" }), "/people/ada/?tab=replies")

@test
A_LINK_THE_BOARD_WRITES_ESCAPES_WHAT_A_PERSON_TYPED()
    // A search box takes whatever anybody types, so the `&` and the space in it have to come back out
    // of `parseSearch` as themselves rather than as two more parameters.
    assertEq(withSearch("/", { q: "two words" }), "/?q=two%20words")
    assertEq(withSearch("/", { tag: "a&b", page: "2" }), "/?tag=a%26b&page=2")
