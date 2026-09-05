// What every test file here needs and nothing more. **It declares no tests of its own**, so
// `slate test tests` walking this directory finds nothing in it to run.
//
// **`await app.handle(request(…))` needs no port, no server and no client**, which is what makes this
// suite run under the interpreter and under node alike, and what keeps it from flaking under load or
// colliding with a development server. What a browser adds is a cookie jar, and that is what `client`
// is: three lines of bookkeeping so that a session and a CSRF token survive from one request to the
// next.

import { request, response } from sluice
import { encodeComponent, parseQuery, percentDecode } from slate:url

// The status of any answer, envelope or not.
export status(reply) -> integer = response(reply).status

// The body of any answer, as text.
export text(reply) -> string = string(response(reply).body)

// One header, whatever case it was written in.
export header(reply, name: string)
    for [k, v] in entries(response(reply).headers)
        if lower(k) == lower(name) then return v

    null

// A JSON answer, as the value it is. **A test reads the document rather than the text**, because what
// a route promises is members and not a byte order.
export doc(reply) -> object
    val said = text(reply)
    val parsed = parseJSON(said)

    if !parsed.ok then throw "that response body is not JSON: " + said

    parsed.value

// Whether markup holds a piece of text.
export shows(reply, what: string) -> boolean = contains(text(reply), what)

// -- a client with a cookie jar -----------------------------------------------------------------------

// `client(app)` -- something that drives `app.handle` the way a browser would.
//
// It keeps the cookies an answer set and sends them back, which is the whole of what a session and a
// double-submit token need: the CSRF cookie is issued on the first GET, the form field on the next
// POST has to match it, and the session cookie is written under a new id every time it is set.
export client(app: object) -> object
    var jar = {}

    // **The query string is taken off the path here**, because `request(method, path, options)` does
    // not read one: it fills `query` from the option of that name, so a test asking for `/?tag=slate`
    // would otherwise reach a handler with an empty query and a path nothing routes.
    async sent(method: string, path: string, options: object) -> object
        val at = indexOf(path, "?")
        val where = if at == null then path else path[0..<at]
        val asked = if at == null then {} else parseQuery(path[at + 1..])
        val query = asked with (options.query ?? {})
        val reply = response(await app.handle(request(method, where,
            options with { cookies: jar, query: query })))

        keep(reply)

        reply

    // The token a form has to carry back, which is the cookie a page would have read.
    token() -> string = jar["csrf"] ?? ""

    async get(path: string) = await sent("GET", path, {})

    async asJson(path: string) = await sent("GET", path, { query: { format: "json" } })

    // A form, posted the way a browser with no script running posts one.
    async form(path: string, fields: object) = await sent("POST", path,
        { headers: { "content-type": "application/x-www-form-urlencoded" },
          body: urlencoded(fields with { _csrf: token() }) })

    // The same route, asked for values -- which is what the page's own program does.
    async post(path: string, fields: object) = await sent("POST", path,
        { headers: { "content-type": "application/json" },
          query: { format: "json" },
          body: toJSON(fields with { _csrf: token() }) })

    // A form carrying a file. **`content` is TEXT**, which is what `slate:http` hands a handler on
    // slate 0.0.29 -- an SVG is a real image and is UTF-8, and everything after the parser is the same
    // code a PNG will take.
    async upload(path: string, fields: object, file: object) = await sent("POST", path,
        { headers: { "content-type": "multipart/form-data; boundary=" + Edge },
          body: multipart(fields with { _csrf: token() }, file) })

    // What the jar is holding, for a test that wants to look.
    cookies() -> object = jar

    // A cookie set out of band, which is how a test forges one.
    put(name: string, value: string)
        jar[name] = value

    keep(reply)
        val set = header(reply, "set-cookie")

        if set == null then return null

        val lines = if set is array then set else [set]

        for line in lines
            val at = indexOf(line, ";")
            val pair = if at == null then line else line[0..<at]
            val eq = indexOf(pair, "=")

            // **A cookie value travels percent-encoded and arrives decoded.** `setCookie` writes the
            // escape and `parseCookies` reads it back, so a jar holding the escaped text hands a guard
            // a signature that is not the one it made.
            if eq != null then jar[pair[0..<eq]] = percentDecode(pair[eq + 1..], false)

        null

    { get: get, asJson: asJson, post: post, form: form, upload: upload, token: token,
      cookies: cookies, put: put, sent: sent }

// -- the two body encodings a browser uses --------------------------------------------------------------

export urlencoded(fields: object) -> string
    var parts = []

    for [name, value] in entries(fields)
        push(parts, encodeComponent(name) + "=" + encodeComponent(string(value)))

    join(parts, "&")

// The boundary this suite writes, which is a string no part's content holds -- which is what RFC 2046
// asks of one.
export val Edge = "----boardtest7f3a"

// A `multipart/form-data` body: the text fields, then one file.
//
// **The CRLF before a delimiter belongs to the delimiter and not to the part**, which is the off-by-one
// every multipart writer and reader has to agree about.
export multipart(fields: object, file) -> string
    var out = ""

    for [name, value] in entries(fields)
        out = out + "--" + Edge + "\r\n"
        out = out + "Content-Disposition: form-data; name=\"" + name + "\"\r\n\r\n"
        out = out + string(value) + "\r\n"

    if file != null
        out = out + "--" + Edge + "\r\n"
        out = out + "Content-Disposition: form-data; name=\"" + file.field + "\"; filename=\""
        out = out + file.filename + "\"\r\n"
        out = out + "Content-Type: " + file.type + "\r\n\r\n"
        out = out + file.content + "\r\n"

    out + "--" + Edge + "--\r\n"

// An image that is text, which is the one kind slate 0.0.29 can carry through a form.
export val Svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"8\" height=\"8\"><rect width=\"8\" height=\"8\"/></svg>"

export picture(name: string) -> object =
    { field: "photo", filename: name, type: "image/svg+xml", content: Svg }
