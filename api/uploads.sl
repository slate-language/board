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
// **THE BYTES GO TO THE DISK AS BYTES.** `slate:fs` answers `readBytes` and `writeBytes`, which is
// the whole of the storage here: what is in the file is the picture, so anything else -- `file(1)`,
// a browser opening it, a backup -- reads it as the picture it is.

import { exists, mkdir, readBytes, readFile, writeBytes, writeFile } from slate:fs
import { sha256 } from slate:crypto
import { encodeWebP, imageShape, readImage, resizeImage } from slate:image
import { base64urlEncode } from slate:url

// Where everything goes, relative to where the server was started.
export val Root = "./uploads"

// -- how big a picture may be, and what one is made into ------------------------------------------------
//
// **THE SIZE IS ASKED OF THE HEADER BEFORE ANYTHING IS DECODED, AND THAT IS THE ORDER THAT MATTERS.**
// A decoded picture is `width * height * channels` bytes however small the file was, so a four-kilobyte
// PNG saying it is 20,000 by 20,000 is 1.2 GB the moment anything reads it -- a compression bomb in a
// picture's clothes, and one that walks straight past a limit on the number of bytes uploaded.
// `imageShape` reads the header and decodes nothing, so a picture claiming more than this is a `413`
// naming the dimensions it claimed, and no memory is ever asked for.
val MaxPixels = 40_000_000

// **THE TWO SIZES ARE `mortar`'s OWN, DOUBLED FOR A RETINA SCREEN.** A photo on a post is at most as
// wide as the column it sits in, which is `--m-measure`, 48rem, 768 CSS pixels; an avatar's largest
// size is `large`, 4rem, 64 CSS pixels, and `.m-avatar` is a circle with `object-fit: cover` on it, so
// what is stored is the square that fills it. Doubling each is what a 2x display asks for and is the
// end of it: a picture stored bigger than that is bytes every reader downloads and no reader sees.
val PhotoWidth = 1536
val AvatarSide = 128

// **A quality is written at every call in `slate:image` and there is no default**, deliberately, so
// these are the board's two numbers. 80 is a photograph on a page; an avatar is small enough that
// what it costs to be generous is nothing, and a face at 128 pixels is where a blocking artefact
// shows most.
val PhotoQuality = 80
val AvatarQuality = 90

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

// `keep(file)` -- one photo on a post; `keepAvatar(file)` -- one picture of a person.
//
// Both answer `{ ok: true, value: "<digest>.png" }`, which is the ORIGINAL's name: what goes in the
// row, what `/uploads/` serves, and what a reader following *view original* gets. Or they answer
// `{ ok: false, status, detail }`, which the caller turns into the answer it was going to give anyway.
//
// **WHAT DIFFERS IS ONLY THE DERIVED COPY, WHICH IS WHAT A PAGE ACTUALLY SHOWS.** A photo's is the
// same picture at most `PhotoWidth` across; an avatar's is the fixed square. Both are WebP -- which is
// smaller than the JPEG of the same picture and keeps an alpha channel, which JPEG cannot -- and both
// are stored beside the original under the digest of their own bytes, so the two files have unrelated
// names and `.display` beside the original is the one line that remembers which is which.
export async keep(file: object) -> object = await taken(file, false)

export async keepAvatar(file: object) -> object = await taken(file, true)

// **NOTHING IS WRITTEN FOR A PICTURE THAT CANNOT BE PROCESSED.** The sniff, the size and the whole
// derivation happen in memory first, so a file that says it is a PNG and will not decode leaves the
// disk exactly as it was -- which is what makes a refusal a refusal rather than a half-kept photo.
async taken(file: object, square: boolean) -> object
    val bytes = file.bytes ?? []
    val kind = kindOf(bytes)

    if kind == null
        return { ok: false, status: 415,
                 detail: "a photo has to be a PNG, a JPEG, a GIF or a WebP, and that is none of them" }

    val name = nameOf(bytes, kind.extension)
    val copy = shown(bytes, kind, square)

    if !copy.ok then return copy

    val ready = await directory(Root)

    if !ready.ok then return { ok: false, status: 500, detail: ready.error }

    val put = await written(name, bytes)

    if !put.ok then return put

    if copy.value != null
        val made = copy.value
        val beside = await written(made.name, made.bytes)

        if !beside.ok then return beside

        val said = await writeFile(displayFile(name), made.name)

        if !said.ok then return { ok: false, status: 500, detail: said.error }

    { ok: true, value: name }

// The derived copy a page shows: `{ ok: true, value: { name, bytes } }`, or `{ ok: true, value: null }`
// where there is to be none.
//
// **A GIF KEEPS ITS ORIGINAL AND NOTHING ELSE.** `readImage` answers the FIRST FRAME of one, so a
// derived copy of an animation is a still of it -- the picture somebody posted would stop moving, and
// a board that quietly did that to a reaction GIF has thrown away what was posted. There is no
// animated WebP encoder here to make one properly with.
//
// **AND A HOST WITH NO IMAGE LIBRARY ALSO KEEPS THE ORIGINAL AND NOTHING ELSE**, which is not a
// concession: `slate:image` is a server module, the board runs under the interpreter, and the page
// asks for the display copy in a way that falls back to the original wherever there is none.
shown(bytes: array, kind: object, square: boolean) -> object
    if kind.extension == "gif" || !imagesHere() then return { ok: true, value: null }

    val shape = imageShape(bytes)

    if !shape.ok
        return { ok: false, status: 415, detail: "that file begins like a picture and its header does " +
                 "not read: " + shape.error }

    if shape.value.width * shape.value.height > MaxPixels
        return { ok: false, status: 413,
                 detail: "that picture says it is " + string(shape.value.width) + " by " +
                     string(shape.value.height) + " pixels, and this board takes " +
                     string(MaxPixels) + " of them at the most" }

    val got = readImage(bytes)

    if !got.ok then return { ok: false, status: 415, detail: got.error }

    val want = if square then squared(got.value, AvatarSide) else fitted(got.value, PhotoWidth)
    val made = encodeWebP(want, if square then AvatarQuality else PhotoQuality)

    { ok: true, value: { name: nameOf(made, "webp"), bytes: made } }

// The same picture at most `width` across, and the picture itself where it is narrower.
//
// **Nothing in `slate:image` keeps the aspect ratio for you** -- `resizeImage` is told both numbers --
// so the height is worked out here, and a row of pixels is never lost to make a picture wider than it
// was.
fitted(img: object, width: integer) -> object
    if img.width <= width then return img

    resizeImage(img, width, max(1, img.height * width / img.width))

// The centred square of a picture, at exactly `side` across.
//
// **It is scaled to COVER the square and then cut, rather than scaled to fit it**, which is what
// `object-fit: cover` does in the page: scaling a wide photograph into a square would squash the face
// in it. Scaling first and cutting second is what keeps this cheap -- the cut walks the small picture
// and never the big one.
squared(img: object, side: integer) -> object
    val short = min(img.width, img.height)
    val wide = max(side, img.width * side / short)
    val tall = max(side, img.height * side / short)
    val big = if wide == img.width && tall == img.height then img else resizeImage(img, wide, tall)

    cut(big, (wide - side) / 2, (tall - side) / 2, side)

// A square of `side` pixels out of `img`, with its top left corner at `x, y`.
cut(img: object, x: integer, y: integer, side: integer) -> object
    var out = []
    var row = y

    while row < y + side
        val at = (row * img.width + x) * img.channels

        out = concat(out, img.pixels[at..<at + side * img.channels])

        row = row + 1

    { width: side, height: side, channels: img.channels, pixels: out }

// One file, written where it is not already there.
//
// **A file already there is the same file**, the name being the digest of what is in it -- so this is
// not a race to lose and the second writer has nothing to say.
async written(name: string, bytes: array) -> object
    if await exists(Root + "/" + name) then return { ok: true }

    val put = await writeBytes(Root + "/" + name, bytes)

    if !put.ok then return { ok: false, status: 500, detail: put.error }

    { ok: true }

// The name a picture has: what it is, and then what kind of thing it is.
export nameOf(bytes: array, extension: string) -> string =
    base64urlEncode(sha256(bytes)) + "." + extension

// Where the display copy of a stored picture is remembered.
//
// **The two files cannot be named after one another**, each being named by the digest of its own
// bytes: a name derived from the original's would make the address of a derived copy a promise about
// how this board resizes, and the answer at that address is cached for a year. So which copy belongs
// to which picture is a fact to write down, and this line is where it is written. **Nothing can ever
// ask for one**: two dots is not a name `minted` accepts.
displayFile(name: string) -> string = Root + "/" + name + ".display"

// The display copy of a stored picture, or `null` where there is none.
//
// **What comes off the disk is checked exactly as what comes off a request is**, which costs one line
// and means this answer can be handed to `stored` with nothing further asked of it.
export async display(name: string)
    if !minted(name) then return null

    val said = await readFile(displayFile(name))

    if !said.ok then return null

    val want = trim(said.value)

    if minted(want) then want else null

// Whether this host can decode a picture at all.
//
// **It asks by trying**, a slate program having no name for the host it is running on: every name in
// `slate:image` refuses under `slate js`, node having no image support in its standard library and a
// browser's being asynchronous where these answer on the spot. The board runs under the interpreter
// and always has an answer here; what this is for is the suite, which runs on both.
var host = null

imagesHere() -> boolean
    if host == null
        var here = true

        try
            imageShape([])
        catch e
            here = false

        host = here

    host

// -- serving one -----------------------------------------------------------------------------------

// `{ ok: true, value: { bytes, type } }` for a photo this board is holding, or `{ ok: false }`.
//
// **A name that is not one this program minted is refused before the disk is touched**, which is the
// whole of the path checking here: a digest, a dot, and one of four extensions is a name with no
// slash, no dot pair and no room for either.
export async stored(name: string) -> object
    if !minted(name)
        return { ok: false, error: "that is not a name this board hands out" }

    val got = await readBytes(Root + "/" + name)

    if !got.ok then return got

    { ok: true, value: { bytes: got.value, type: typeOf(name) } }

// Whether a name is a digest, one dot and one of the four extensions -- and nothing else at all.
//
// **This is the whole of the path checking, and it is a whitelist rather than a search for anything
// bad.** 43 characters of the base64url alphabet leave no room for a slash, a dot pair, a NUL, a
// backslash or a percent escape, so `../../etc/passwd`, `..%2fserver.sl` and `a%00.png` are all
// refused by the same sentence and none of them is a case anybody had to think of. **The length is
// exact**: 43 characters is what the base64url of a SHA-256 is, and one dot is what a name minted
// here has, so `<digest>.png.png` is not one either.
export minted(name) -> boolean
    val said = string(name ?? "")
    val at = indexOf(said, ".")

    if at != 43 then return false
    if typeOf(said) == null then return false
    if indexOf(said[at + 1..], ".") != null then return false

    var i = 0

    while i < at
        if !base64url(said[i..<i + 1]) then return false

        i = i + 1

    true

base64url(c: string) -> boolean
    val letter = (c >= "a" && c <= "z") || (c >= "A" && c <= "Z")
    val digit = c >= "0" && c <= "9"

    letter || digit || c == "-" || c == "_"

// -- the disk ---------------------------------------------------------------------------------------

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
