// Photos, on the disk.
//
// **A photo is a file under `uploads/<what>/<id>/`, served back through `slate:http`'s own
// `files(root)`.** A database is a poor place for a picture -- every row read carries it, every backup
// carries it, and a web server already knows how to answer a byte range with an `ETag`. What the row
// keeps is the path.
//
// **What is stored is a name this program made and not a name a client sent.** A filename is text a
// stranger wrote: `../../etc/passwd` is the obvious shape and the one every file server has been
// caught by, and a name with a slash, a newline or two hundred characters in it is the same mistake
// in a longer form.
//
// **UPLOADS ARE TEXT ON slate 0.0.29, AND THAT IS THE SERVER UNDER THIS.** `serve` reads a body whole
// and hands a handler a STRING, and a body that is not valid UTF-8 becomes the empty string on the
// way -- so a `.png` posted here arrives as nothing at all, with no header, no status and no fault.
// An **SVG is a real image and is UTF-8 text**, so it goes through this path today exactly as a PNG
// will; everything below -- the checks, the naming, the directory, the row, the `<img>` -- is the same
// code either way.

import { mkdir, writeFile } from slate:fs

// Where everything goes, relative to where the server was started.
export val Root = "./uploads"

// The file a form sent under `field`, or `null` where it sent none.
//
// **A file input a person left alone still posts a part**, with an empty filename and no content, so
// "there is no photo" is a thing to test for rather than an absent member.
export pick(req: object, field: string)
    val form = req.form ?? null

    if form == null then return null

    for file in form.files ?? []
        if file.field == field && (file.filename ?? "") != "" then return file

    null

// `keep(what, id, file)` -- one photo, written under `uploads/<what>/<id>/`.
//
// It answers `{ ok: true, value: "<what>/<id>/<name>" }`, which is what goes in the row and what the
// page puts after `/uploads/`; or `{ ok: false, status, detail }`, which the caller turns into the
// answer it was going to give anyway.
export async keep(what: string, id: integer, file: object) -> object
    val kind = lower(file.type ?? "")

    // **What the client CLAIMED, and it is worth exactly that.** A real board sniffs the first bytes
    // as well -- the magic number of a PNG, a JPEG, a GIF, a WebP -- which needs a body this server
    // does not yet hand over as bytes. The header is the check that can be made today and it is
    // stated as such rather than passed off as more than it is.
    if !startsWith(kind, "image/")
        return { ok: false, status: 415, detail: "a photo has to be an image, and that is " + kind }

    val name = safeName(file.filename ?? "photo")
    val here = Root + "/" + what + "/" + string(id)

    val ready = await directory(here)

    if !ready.ok then return { ok: false, status: 500, detail: ready.error }

    val put = await writeFile(here + "/" + name, file.content ?? "")

    if !put.ok then return { ok: false, status: 500, detail: put.error }

    { ok: true, value: what + "/" + string(id) + "/" + name }

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

// A name of this program's own making, out of the one a client sent.
//
// **Everything that is not a letter, a digit, a dot, a dash or an underscore becomes a dash**, which
// takes the whole class of path mistakes away rather than looking for the ones already known: a slash,
// a backslash, a `..`, a newline, a null, a colon on a filesystem that cares about drives. A leading
// dot goes too, a file beginning with one being hidden and `..` being the case everybody means.
export safeName(sent: string) -> string
    var out = ""

    for c in chars(trim(sent))
        out = out + (if allowed(c) then c else "-")

    while startsWith(out, ".") || startsWith(out, "-")
        out = out[1..]

    if out == "" then out = "photo"

    if len(out) > 80 then out[0..<80] else out

// **Nothing continues a line in slate, a leading operator included**, so a long condition is a block
// with the halves bound to names rather than an expression wrapped across two lines.
allowed(c: string) -> boolean
    val letter = (c >= "a" && c <= "z") || (c >= "A" && c <= "Z")
    val digit = c >= "0" && c <= "9"
    val punctuation = c == "." || c == "_" || c == "-"

    letter || digit || punctuation
