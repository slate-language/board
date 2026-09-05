// The document the markup goes in.
//
// **Everything a page needs to start is already in the response**, which is the whole of what server
// rendering buys: the markup, the stylesheet, and the values the page was rendered from. The browser
// program adopts the markup and reads the values back rather than asking for either again, so the
// first paint owes nothing to a network round trip and a reader with no JavaScript sees the same page.
//
// **This file writes text and imports no host**, so `tests/pages.sl` reads its answer with nothing
// running.

// The whole document.
//
// `markup` is what `lath`'s string host made of `App`, and `state` is what `client.slx` reads back out
// of `#board-state` in order to hydrate against exactly what was rendered.
export page(title: string, theme: string, markup: string, state: object) -> string
    val head = "<!doctype html>
<html lang=\"en\" class=\"" + theme + "\">
<head>
<meta charset=\"utf-8\">
<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
<title>" + escaped(title) + "</title>
<link rel=\"stylesheet\" href=\"/assets/style.css\">
</head>
<body>
<div id=\"app\">"

    val tail = "</div>
<script type=\"application/json\" id=\"board-state\">" + stateText(state) + "</script>
<script src=\"/assets/app.js\" defer></script>
</body>
</html>
"

    head + markup + tail

// **A `<` inside the state is written as `\\u003c`**, which is the one thing that can end a
// `<script>` early: a JSON document holding `</script>` in a post's text would close the element and
// the rest of it would be parsed as HTML. Escaping the character rather than the sequence is what
// makes that true of `<!--` as well, and `JSON.parse` reads the escape back as the character.
export stateText(state: object) -> string = replace(toJSON(state), "<", "\\u003c")

// The five characters that may not travel as themselves in markup this file writes.
//
// **Nothing else here is escaped, because nothing else here is built out of text.** The page's own
// content is `lath`'s, whose DOM host builds text nodes and whose string host escapes as it
// serialises -- so a title is the one string this file interpolates and this is the one place it can
// go wrong.
export escaped(s: string) -> string =
    val a = replace(s, "&", "&amp;")
    val b = replace(a, "<", "&lt;")
    val c = replace(b, ">", "&gt;")
    val d = replace(c, "\"", "&quot;")

    replace(d, "'", "&#39;")

// What the tab says, per page. **The page's own name first**, which is what a person scanning twenty
// tabs is reading.
export titleOf(data: object) -> string
    val page = data.page ?? "missing"

    if page == "list" then return "the board"
    if page == "thread" then return data.thread.title + " -- the board"
    if page == "compose" then return "Start a thread -- the board"
    if page == "signin" then return "Sign in -- the board"
    if page == "signup" then return "Join -- the board"
    if page == "profile" then return data.who.name + " -- the board"
    if page == "admin" then return "Admin -- the board"

    "Nothing here -- the board"
