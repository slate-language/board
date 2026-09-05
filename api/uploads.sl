// Photos, on the disk.
//
// **A photo is named by its own content and by nothing else.** The file is `<digest>.<extension>`,
// where the digest is the SHA-256 of the bytes -- so the same picture posted twice is one file, a
// name a client sent never reaches the filesystem at all, and the address a page renders can be
// cached for ever because nothing at it can ever change. That is what makes the whole class of
// filename mistakes -- `../../etc/passwd`, a newline, a colon, two hundred characters, a name that
// collides with somebody else's -- not a thing to defend against but a thing that cannot be said.
//
// **What is on the disk is not what a row says.** A database is a poor place for a picture: every
// row read carries it and every backup carries it. The row keeps the name; the bytes are a file.
//
// **WHAT KIND OF PICTURE IT IS IS READ OFF THE FIRST BYTES AND NEVER OFF THE HEADER.** A
// `Content-Type` is what a client claimed and is worth exactly that; a PNG begins with eight bytes
// that say so. Only the four raster formats a browser shows are taken. **An SVG is deliberately not
// among them**: it is a document with script in it, and a board that served one from its own origin
// would be serving somebody else's JavaScript to its readers.
//
// **slate CANNOT WRITE BYTES TO A FILE, WHICH IS WHY `bytesTo` AND `bytesOf` EXIST.** `slate:fs`
// answers `readBytes` and has no `writeBytes`, and `writeFile` renders anything that is not a string
// the way `print` would -- so a byte array written straight out lands on the disk as the text
// `[137, 80, 78, ...]`. Until that name exists the bytes are kept base64url-encoded and decoded on
// the way out, which is a private arrangement between these two functions: no other file here knows
// it, and the day `writeBytes` lands each of them becomes one call. Reported to the compiler
// 2026-09-05, with `req.bytes` -- which arrived in 0.0.30 for exactly this path -- as the argument
// that the other half is missing.

import { exists, mkdir, readFile, writeFile } from slate:fs
import { sha256 } from slate:crypto
import { base64urlDecode, base64urlEncode } from slate:url

// Where everything goes, relative to where the server was started.
export val Root = "./uploads"

// The four formats a photo may be, each by the bytes it begins with.
//
// **`at` is where the mark stands**, which is 0 for three of them and 8 for a WebP -- a RIFF
// container names its own kind after the size.
val Kinds = [{ type: "image/png", extension: "png", at: 0, mark: [137, 80, 78, 71, 13, 10, 26, 10] },
             { type: "image/jpeg", extension: "jpg", at: 0, mark: [255, 216, 255] },
             { type: "image/gif", extension: "gif", at: 0, mark: [71, 73, 70, 56] },
             { type: "image/webp", extension: "webp", at: 8, mark: [87, 69, 66, 80] }]

// -- what a form sent ---------------------------------------------------------------------------------

// The file a form sent under `field`, or `null` where it sent none.
//
// **A file input a person left alone still posts a part**, with an empty filename and no content, so
// "there is no photo" is a thing to test for rather than an absent member.
export pick(req: object, field: string)
    val form = req.form ?? null

    if form == null then return null

    for file in form.files ?? []
        if file.field == field && len(file.bytes ?? []) > 0 then return file

    null

// -- what it is -----------------------------------------------------------------------------------

// `{ type, extension }` for a picture this board will serve, or `null` for anything else.
export kindOf(bytes: array)
    for kind in Kinds
        if begins(bytes, kind.mark, kind.at) then return { type: kind.type, extension: kind.extension }

    null

begins(bytes: array, mark: array, at: integer) -> boolean
    if len(bytes) < at + len(mark) then return false

    var i = 0

    while i < len(mark)
        if bytes[at + i] != mark[i] then return false

        i = i + 1

    true

// The kind a stored name says it is. **The name was minted here**, so this reads a file this program
// wrote rather than anything a client said.
export typeOf(name: string)
    for kind in Kinds
        if endsWith(name, "." + kind.extension) then return kind.type

    null

// -- keeping one ---------------------------------------------------------------------------------

// `keep(file)` -- one photo, written under `uploads/` and named by its content.
//
// It answers `{ ok: true, value: "<digest>.png" }`, which is what goes in the row and what a page
// puts after `/uploads/`; or `{ ok: false, status, detail }`, which the caller turns into the answer
// it was going to give anyway.
export async keep(file: object) -> object
    val bytes = file.bytes ?? []
    val kind = kindOf(bytes)

    if kind == null
        return { ok: false, status: 415,
                 detail: "a photo has to be a PNG, a JPEG, a GIF or a WebP, and that is none of them" }

    val name = nameOf(bytes, kind.extension)
    val ready = await directory(Root)

    if !ready.ok then return { ok: false, status: 500, detail: ready.error }

    // **A file already there is the same file**, the name being the digest of what is in it -- so
    // this is not a race to lose and the second writer has nothing to say.
    if await exists(Root + "/" + name) then return { ok: true, value: name }

    val put = await bytesTo(Root + "/" + name, bytes)

    if !put.ok then return { ok: false, status: 500, detail: put.error }

    { ok: true, value: name }

// The name a picture has: what it is, and then what kind of thing it is.
export nameOf(bytes: array, extension: string) -> string =
    base64urlEncode(sha256(bytes)) + "." + extension

// -- serving one -----------------------------------------------------------------------------------

// `{ ok: true, value: { bytes, type } }` for a photo this board is holding, or `{ ok: false }`.
//
// **A name that is not one this program minted is refused before the disk is touched**, which is the
// whole of the path checking here: a digest, a dot, and one of four extensions is a name with no
// slash, no dot pair and no room for either.
export async stored(name: string) -> object
    val type = typeOf(name ?? "")

    if type == null || !minted(name)
        return { ok: false, error: "that is not a name this board hands out" }

    val got = await bytesOf(Root + "/" + name)

    if !got.ok then return got

    { ok: true, value: { bytes: got.value, type: type } }

// Whether a name is a digest and an extension and nothing else.
minted(name: string) -> boolean
    val at = indexOf(name, ".")

    if at == null then return false

    var i = 0

    while i < at
        if !base64url(name[i..<i + 1]) then return false

        i = i + 1

    at == 43

base64url(c: string) -> boolean
    val letter = (c >= "a" && c <= "z") || (c >= "A" && c <= "Z")
    val digit = c >= "0" && c <= "9"

    letter || digit || c == "-" || c == "_"

// -- the disk ---------------------------------------------------------------------------------------

// The two calls that will be one each the day `slate:fs` grows a `writeBytes`. See the note at the
// top of this file: `writeFile` renders a byte array the way `print` would, so what is on the disk is
// the bytes base64url-encoded and nothing else in this program knows that.
async bytesTo(file: string, bytes: array) -> object = await writeFile(file, base64urlEncode(bytes))

async bytesOf(file: string) -> object
    val text = await readFile(file)

    if !text.ok then return text

    base64urlDecode(text.value)

// The directories of a path, made one at a time.
//
// **`mkdir` makes one directory and not a chain of them**, which is `mkdir(2)`'s own rule and node's,
// so this walks the path. A directory that is already there is not a failure here: two people posting
// photos at once is the ordinary case and the second one is not wrong.
async directory(dir: string) -> object
    var walked = ""

    for part in split(dir, "/")
        if part == "" then continue

        walked = if walked == "" then part else walked + "/" + part

        val r = await mkdir(walked)

        if !r.ok && !contains(r.error, "EEXIST") then return r

    { ok: true }
