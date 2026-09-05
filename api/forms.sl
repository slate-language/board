// Two guards this application had to write, and both are about the same thing: **`sluice` is an API
// framework, and a board is a page with forms on it.**
//
// `given(Shape)` reads a body a BROWSER sent -- `application/x-www-form-urlencoded` from a plain form,
// `multipart/form-data` from one carrying a file, `application/json` from the page's own program --
// where `sluice`'s `body(Shape)` reads JSON and nothing else.
//
// `formCsrf()` takes the double-submit token out of a hidden FIELD as well as out of a header, where
// `sluice`'s `csrf()` takes only a header -- which a form posted by a browser with no script running
// cannot set. It also hands the token to the handler, so that the page being rendered can put the
// value into the field that will come back.
//
// **Both belong in `sluice` and neither is a criticism of it**: every line here is written over that
// package's own public surface -- `guardOf`, `problem`, `response` -- and would be four options and
// no new ideas there.

import { guardOf, problem, response } from sluice
import { multipart } from sluice
import { parseForm, setCookie } from slate:http
import { randomBytes, timingSafeEqual } from slate:crypto
import { base64urlEncode } from slate:url

// The methods a token is asked for.
val Unsafe = ["POST", "PUT", "PATCH", "DELETE"]

// The field a form carries the token in. **It is lifted off the body before the shape sees it**, so
// an application's own declaration says what the form is about and not how it is defended.
val TokenField = "_csrf"

// -- the body ---------------------------------------------------------------------------------------

// `given(Shape, options)` -- whatever a browser posted, checked against `Shape` and handed on under
// `body`.
//
// **The declaration is the validator.** `Shape.mismatch` walks the value collecting every reason it
// does not fit rather than stopping at the first, so somebody filling in a form is told about all of
// it at once -- which is `sluice`'s own arrangement, kept.
//
// `options` are `multipart`'s: `limit` in bytes, answered with `413`.
export given(shape: shape, options: object = {}, handler = null) =
    val g = guardOf("given(" + shape.name() + ")", (h) -> dispatch(shape, options, h))

    if handler == null then g else g(handler)

dispatch(shape: shape, options: object, h)
    // **The multipart guard is built ONCE and not per request**, which is what `stack` does with
    // every other guard and is the reason a route composes when it is added rather than when it is
    // called.
    val viaFiles = multipart(options, (req) -> lifted(shape, h, req, req.form.fields))

    async inner(req)
        val kind = lower(req.headers["content-type"] ?? "")

        if startsWith(kind, "multipart/") then return await viaFiles(req)

        if startsWith(kind, "application/json")
            val parsed = parseJSON(req.body ?? "")

            // **A body that will not parse is a 400 and not a fault**, which is slate's own division:
            // text from a socket is a condition every server was always going to handle.
            if !parsed.ok
                return problem(400, "Bad Request", "the request body is not JSON",
                    { instance: req.path, parse: parsed.error })

            return await lifted(shape, h, req, parsed.value)

        await lifted(shape, h, req, parseForm(req.body ?? ""))

    inner

// The token out of the values, then the rest against the shape.
lifted(shape: shape, h, req: object, values)
    if !(values is object)
        return problem(400, "Bad Request", "the request body is not a set of fields",
            { instance: req.path })

    var fields = {}
    var token = null

    for [name, value] in entries(values)
        if name == TokenField then token = string(value) else fields[name] = value

    val bad = shape.mismatch(fields)

    if len(bad) != 0
        return problem(400, "Bad Request", "the form does not fit " + shape.name(),
            { instance: req.path, mismatch: bad })

    h(req with { body: fields, token: token })

// -- the token --------------------------------------------------------------------------------------

// `formCsrf(options)` -- a random token in a cookie a script can read, required back on every unsafe
// method in the `_csrf` field or the `x-csrf-token` header.
//
// **A form posted from another site carries the cookie** -- browsers send those -- **and cannot read
// it**, because reading it needs script running on this origin. `SameSite=Lax` on the session cookie
// is the first line and this is the depth behind it.
//
// **The token is minted BEFORE the handler runs and put on `req.csrf`.** That is the difference this
// application needed: a page rendered on the server has to write the token into the form it is
// rendering, so a token issued on the way out -- after the markup was built -- arrives one request too
// late and the first form anybody meets is refused.
export formCsrf(options: object = {}, handler = null) =
    val g = guardOf("formCsrf", (h) -> tokened(options, h))

    if handler == null then g else g(handler)

tokened(options: object, h)
    val name = options.name ?? "csrf"
    val header = lower(options.header ?? "x-csrf-token")

    async inner(req)
        val held = req.cookies[name] ?? null
        val token = held ?? base64urlEncode(randomBytes(32))

        if unsafe(req.method)
            val sent = req.token ?? (req.headers[header] ?? null)

            if held == null || sent == null
                return problem(403, "Forbidden",
                    "this request needs a `" + TokenField + "` field or an `" + header + "` header "
                        + "matching the `" + name + "` cookie",
                    { instance: req.path })

            // **`timingSafeEqual` and not `==`**, which stops at the first byte that differs and
            // tells whoever is guessing how much of a forged token was right.
            if !timingSafeEqual(toBytes(held), toBytes(sent))
                return problem(403, "Forbidden",
                    "the token does not match the `" + name + "` cookie", { instance: req.path })

        val reply = await h(req with { csrf: token })

        if held != null then return reply

        // **This is the one cookie deliberately not `HttpOnly`**, and the whole double-submit
        // argument rests on it: a page has to be able to read the token in order to send it back.
        withCookie(reply, setCookie(name, token,
            { httpOnly: false, sameSite: "Lax", path: "/", secure: overHttps(req) }))

    inner

unsafe(method: string) -> boolean
    for m in Unsafe
        if m == upper(method) then return true

    false

overHttps(req: object) -> boolean = (req.headers["x-forwarded-proto"] ?? "") == "https"

// One more `Set-Cookie` on an answer, whatever else it already carried.
//
// **A repeated header name is an ARRAY**, which is what `slate:http` takes and the only way to say
// `Set-Cookie` twice: an object has one value per name and HTTP does not. A login writing a session
// and a token together is exactly that case.
export withCookie(reply, cookie: string) -> object
    val out = response(reply)
    val headers = out.headers ?? {}
    val had = headers["Set-Cookie"] ?? (headers["set-cookie"] ?? null)
    val all = if had == null then cookie elif had is array then concat(had, [cookie]) else [had, cookie]

    out with { headers: headers with { "Set-Cookie": all } }
