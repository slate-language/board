// A photo on its way to the disk.
//
// **What these are about is that nothing a stranger wrote decides anything.** The kind is read off
// the first bytes and never off the header, and the name is the digest of the content and never the
// one a client sent.
//
// **The multipart body itself is `sluice`'s to read and `sluice`'s to test.** Its `multipart` guard
// parses `req.bytes` as of 0.4.0, refuses a body over `maxBytes` with a `413` and a part its
// `accept` predicate turns down with a `415`; what this board owns is the predicate, the naming and
// the disk. `tests/routes.sl` is where the two meet, over a real multipart body.
//
// They write under `uploads/`, which is where the running board writes too, and take what they wrote
// away again -- so running them twice does what running them once did.

import { exists } from slate:fs

import { display, keep, kindOf, nameOf, pick, stored, typeOf, Root } from "../api/uploads.sl"
import { decodes, picture, program, swept, Png, PngName } from "./support.sl"

// A request as `sluice`'s `multipart` guard would have left it.
carrying(files: array) -> object = { form: { fields: {}, files: files } }

// The photos a test wrote, taken away by `@teardown` however the test went.
//
// **The sweep is the teardown's and not the test's, and that is the whole reason it is here**: a
// failed assertion above `swept` leaves the file on the disk, and the next run then reads what this
// one wrote rather than what it wrote itself.
var wrote = []

@setup
nothingWrittenYet()
    wrote = []

@teardown
async sweep()
    for name in wrote
        await swept(name)

    null

// -- what kind of thing it is ------------------------------------------------------------------------

@test
THE_FOUR_FORMATS_A_BROWSER_SHOWS_ARE_READ_OFF_THEIR_FIRST_BYTES()
    assertEq(kindOf(Png).type, "image/png")
    assertEq(kindOf(Png).extension, "png")
    assertEq(kindOf([255, 216, 255, 224, 0, 16]).type, "image/jpeg")
    assertEq(kindOf(toBytes("GIF89a") ).type, "image/gif")

    // **A WebP says what it is after its own size**, a RIFF container naming its kind at byte eight.
    assertEq(kindOf(concat(toBytes("RIFF"), concat([36, 0, 0, 0], toBytes("WEBP")))).type, "image/webp")

@test
ANYTHING_ELSE_IS_NOT_A_PICTURE_HOWEVER_IT_IS_LABELLED()
    assertEq(kindOf(toBytes("#!/bin/sh\nrm -rf /\n")), null)
    assertEq(kindOf([]), null)
    assertEq(kindOf([137, 80]), null)

    // **An SVG is a real image and is deliberately not taken**: it is a document with script in it,
    // and a board serving one from its own origin would be serving somebody else's JavaScript.
    assertEq(kindOf(toBytes("<svg xmlns=\"http://www.w3.org/2000/svg\"/>")), null)

@test
A_STORED_NAME_SAYS_WHAT_IT_IS_AND_ANYTHING_ELSE_SAYS_NOTHING()
    assertEq(typeOf(PngName), "image/png")
    assertEq(typeOf("x.webp"), "image/webp")
    assertEq(typeOf("x.exe"), null)
    assertEq(typeOf(""), null)

// -- what it is called --------------------------------------------------------------------------------

@test
A_PHOTO_IS_NAMED_BY_ITS_OWN_CONTENT()
    assertEq(nameOf(Png, "png"), PngName)

    // The same bytes are the same name, and one byte different is a different one.
    assertEq(nameOf(Png, "png"), nameOf(concat(Png, []), "png"))
    assert(nameOf(Png, "png") != nameOf(concat(Png, [0]), "png"))

// -- what a form sent -----------------------------------------------------------------------------------

@test
A_FILE_INPUT_SOMEBODY_LEFT_ALONE_IS_NOT_A_PHOTO()
    // **A file input a person did not touch still posts a part**, with an empty filename and nothing
    // in it, so "there is no photo" is a thing to test for rather than an absent member.
    assertEq(pick(carrying([{ field: "photo", filename: "", type: "", bytes: [] }]), "photo"), null)
    assertEq(pick(carrying([]), "photo"), null)
    assertEq(pick({}, "photo"), null)

@test
A_FILE_IS_FOUND_BY_THE_FIELD_IT_WAS_SENT_UNDER()
    val two = carrying([{ field: "other", filename: "a.png", type: "image/png", bytes: Png },
                        picture("b.png")])

    assertEq(pick(two, "photo").filename, "b.png")

// -- the disk ------------------------------------------------------------------------------------------

@test
async A_PHOTO_IS_WRITTEN_UNDER_ITS_OWN_NAME_AND_COMES_BACK_THE_SAME()
    push(wrote, PngName)

    val put = await keep(picture("square.png"))

    assert(put.ok, "the write worked")
    assertEq(put.value, PngName)

    val back = await stored(PngName)

    assert(back.ok)
    assertEq(back.value.type, "image/png")
    assertEq(back.value.bytes, Png)

@test
async THE_DISPLAY_COPY_IS_REMEMBERED_BESIDE_THE_ORIGINAL_AND_CANNOT_BE_ASKED_FOR()
    if !decodes() then skip("waiting on slate:image reaching the JavaScript host: nothing there decodes a picture")

    // **The two files cannot be named after one another**, each being named by the digest of its own
    // bytes -- so which copy belongs to which picture is a fact to write down, and `<original>.display`
    // is where it is written.
    push(wrote, PngName)

    await keep(picture("square.png"))

    val made = await display(PngName)

    assert(made != null, "a display copy was made and written down")
    assert(endsWith(made, ".webp"), "and it is a WebP")
    assert(await exists(Root + "/" + made), "which is really there")

    // **Nothing can ever ask for the line itself.** Two dots is not a name `minted` accepts, so the
    // one route that serves this directory cannot reach it.
    assert(!(await stored(PngName + ".display")).ok)

@test
async SOMETHING_THAT_IS_NOT_AN_IMAGE_IS_REFUSED_BEFORE_ANYTHING_IS_WRITTEN()
    val put = await keep(program("innocent.png"))

    assert(!put.ok)
    assertEq(put.status, 415)
    assertEq(await exists(Root + "/" + nameOf(program("x").bytes, "png")), false)

@test
async A_NAME_THIS_PROGRAM_DID_NOT_MINT_IS_REFUSED_BEFORE_THE_DISK_IS_TOUCHED()
    // **A digest, a dot and one of four extensions is a name with no slash in it and no room for
    // one**, so a path is not something a request can write.
    assert(!(await stored("../../etc/passwd")).ok)
    assert(!(await stored("../" + PngName)).ok)
    assert(!(await stored("short.png")).ok)
    assert(!(await stored(PngName + ".exe")).ok)

@test
async A_PHOTO_THAT_IS_NOT_THERE_IS_AN_ANSWER_AND_NOT_A_FAULT()
    // A name shaped exactly as one this board hands out, for a picture nobody ever posted.
    val got = await stored(nameOf(toBytes("a photograph nobody took"), "png"))

    assert(!got.ok)
    assert(contains(got.error, "uploads"))
