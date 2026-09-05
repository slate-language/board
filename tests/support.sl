// What every test file here needs and nothing more. **It declares no tests of its own**, so
// `slate test tests` walking this directory finds nothing in it to run.
//
// **`await app.handle(request(…))` needs no port, no server and no client**, which is what makes this
// suite run under the interpreter and under node alike, and what keeps it from flaking under load or
// colliding with a development server. What a browser adds is a cookie jar, and that is what `client`
// is: three lines of bookkeeping so that a session and a CSRF token survive from one request to the
// next.

import { request, response } from sluice
import { remove } from slate:fs
import { encodePNG, imageShape, resizeImage } from slate:image
import { encodeComponent, parseQuery, percentDecode } from slate:url

import { display, Root } from "../api/uploads.sl"

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
        val built = request(method, where, options with { cookies: jar, query: query })

        // **`request` fills in what a server fills in and knows nothing about `bytes`**, which
        // arrived on slate 0.0.30 and has not reached `sluice`'s helper yet -- so an upload's body is
        // put on afterwards. A real server sets both; a body that is not UTF-8 has no `body` at all,
        // which is exactly the case a photograph is.
        val req = if has(options, "bytes") then built with { bytes: options.bytes } else built
        val reply = response(await app.handle(req))

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

    // A form carrying a file. **The body goes as BYTES and there is no text form of it**, which is
    // what a browser posting a `.png` really sends and what `req.bytes` is for.
    async upload(path: string, fields: object, file: object) = await sent("POST", path,
        { headers: { "content-type": "multipart/form-data; boundary=" + Edge },
          bytes: multipart(fields with { _csrf: token() }, file) })

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

// A `multipart/form-data` body: the text fields, then one file, as BYTES.
//
// **Bytes and not text, because a photograph is not text.** The headers are ASCII and the file is
// whatever it is, which is the whole reason this body cannot be built as a string -- and the reason
// `api/multipart.sl` reads `req.bytes`.
//
// **The CRLF before a delimiter belongs to the delimiter and not to the part**, which is the
// off-by-one every multipart writer and reader has to agree about.
export multipart(fields: object, file) -> array
    var out = []

    for [name, value] in entries(fields)
        val head = "--" + Edge + "\r\nContent-Disposition: form-data; name=\"" + name + "\"\r\n\r\n"

        out = concat(out, toBytes(head + string(value) + "\r\n"))

    if file != null
        val said = "--" + Edge + "\r\nContent-Disposition: form-data; name=\"" + file.field + "\""
        val named = said + "; filename=\"" + file.filename + "\"\r\n"
        val head = named + "Content-Type: " + file.type + "\r\n\r\n"

        out = concat(out, toBytes(head))
        out = concat(out, file.bytes ?? [])
        out = concat(out, toBytes("\r\n"))

    concat(out, toBytes("--" + Edge + "--\r\n"))

// A real PNG, and the smallest one there is: eight bytes that say what it is, a header, one
// transparent pixel and the end. **A fixture that is really a PNG is the point** -- what a photo is
// is read off these bytes and never off the `Content-Type` a client wrote.
export val Png = [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0,
                  1, 8, 6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 218, 99, 252,
                  207, 192, 80, 15, 0, 4, 133, 1, 128, 132, 169, 140, 33, 0, 0, 0, 0, 73, 69, 78, 68,
                  174, 66, 96, 130]

// What that PNG is called once it is kept: the base64url of its own SHA-256, and then what it is.
export val PngName = "xBTNDiBN6XT3N1PH4o12OOezaRu4saK6trJbt_7Xznc.png"

export picture(name: string) -> object =
    { field: "photo", filename: name, type: "image/png", bytes: Png }

// A file that is not a picture at all, however it is labelled.
export program(name: string) -> object =
    { field: "photo", filename: name, type: "image/png", bytes: toBytes("#!/bin/sh\nrm -rf /\n") }

// A real WebP, and near enough the smallest one there is: eight pixels a side, lossy at 80. **It is
// here as bytes rather than as a call to `encodeWebP`** because what it is for is proving that a
// WebP is a picture this board takes at all, and that answer must be the same on a host that cannot
// encode one.
export val Webp = [82, 73, 70, 70, 104, 0, 0, 0, 87, 69, 66, 80, 86, 80, 56, 32, 92, 0, 0, 0, 208,
                   1, 0, 157, 1, 42, 8, 0, 8, 0, 1, 64, 38, 37, 176, 2, 116, 1, 14, 103, 210, 197,
                   160, 0, 254, 245, 242, 157, 204, 182, 77, 6, 46, 143, 255, 128, 157, 165, 202,
                   197, 115, 208, 128, 128, 154, 44, 136, 15, 117, 210, 3, 252, 37, 41, 222, 255,
                   99, 102, 197, 126, 207, 175, 246, 55, 255, 151, 240, 241, 237, 255, 54, 182, 60,
                   191, 227, 254, 81, 53, 114, 191, 209, 38, 63, 240, 67, 255, 226, 15, 209, 128,
                   0, 0]

export val WebpName = "j8lD578diPLdc81pHzCJaGtpssOvV7uD4Rb0CrhnKT8.webp"

export webp(name: string) -> object =
    { field: "photo", filename: name, type: "image/webp", bytes: Webp }

// A real GIF, one white pixel of it. **What a GIF is for here is the format that keeps its original
// and nothing else**, `readImage` answering the first frame of one and a still of an animation being
// a picture nobody posted.
export val Gif = [71, 73, 70, 56, 57, 97, 1, 0, 1, 0, 128, 0, 0, 0, 0, 0, 255, 255, 255, 33, 249, 4,
                  1, 0, 0, 0, 0, 44, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 1, 68, 0, 59]

export val GifName = "7xlVrnV8i5ZsgySDUDMb06MPZYztEfOH-OvwWrM2hik.gif"

export gif(name: string) -> object =
    { field: "photo", filename: name, type: "image/gif", bytes: Gif }

// **FORTY-FIVE BYTES THAT SAY THEY ARE A HUNDRED AND FORTY-FOUR MILLION PIXELS.** A signature, an
// `IHDR` claiming 12,000 by 12,000, and the end -- which is a compression bomb in a picture's
// clothes and walks straight past any limit on the number of bytes uploaded, because the file really
// is this small. What stops it is `imageShape`, which reads these bytes and decodes none of them.
export val Bomb = [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 46, 224, 0, 0,
                   46, 224, 8, 2, 0, 0, 0, 222, 39, 27, 166, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96,
                   130]

export bomb(name: string) -> object =
    { field: "photo", filename: name, type: "image/png", bytes: Bomb }

// A real PNG of any size at all, built rather than written down: `Png` is 71 bytes because it is one
// pixel, and a picture wide enough to be scaled down is thousands however it is made.
//
// **`slate:image` BUILDS IT, SO ASKING FOR ONE IS ITSELF A DECODE** -- which is why every test that
// wants one is a test that skips where the library is not. Importing a name a back end does not have
// is fine; reaching it is what refuses.
export wide(width: integer, height: integer) -> array
    val seed = { width: 4, height: 2, channels: 3,
                 pixels: [220, 40, 40, 40, 220, 40, 40, 40, 220, 240, 240, 40,
                          40, 220, 220, 220, 40, 220, 20, 20, 20, 250, 250, 250] }

    encodePNG(resizeImage(seed, width, height))

// -- the host, and the disk it wrote on ---------------------------------------------------------------

var decoding = null

// Whether this host can decode a picture at all, asked once by trying.
//
// **A slate program has no name for the host it is running on**, so the probe is the call itself:
// every name in `slate:image` refuses under `slate js`, node having no image support in its standard
// library and a browser's being asynchronous where these answer on the spot. `api/uploads.sl` asks
// the same question in the same way, which is why a display copy is something that is there under
// the interpreter and simply absent under node -- and why a test about one skips rather than fails.
export decodes() -> boolean
    if decoding == null
        var here = true

        try
            imageShape([])
        catch e
            here = false

        decoding = here

    decoding

// A photo a test wrote, taken away again -- so that running a suite twice does what running it once
// did. **The file is named by its content**, so there is exactly one of them however many tests
// posted it.
//
// **KEEPING ONE PHOTO WRITES UP TO THREE FILES**, and a sweep that forgets two of them leaves a
// working directory that fills up: the original, the WebP copy a page shows, and the one line beside
// the original that says which copy is which. `display` is what reads that line, so it is asked
// before anything is taken away.
export async swept(name: string)
    val made = await display(name)

    if made != null then await remove(Root + "/" + made)

    await remove(Root + "/" + name + ".display")
    await remove(Root + "/" + name)

    null
