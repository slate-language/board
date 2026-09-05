// A photo on its way to the disk.
//
// **The name a client sent is text a stranger wrote**, so what these are about is that the file that
// ends up on the disk is named by this program and lands where this program meant it to.
//
// They write under `uploads/`, which is where the running board writes too, and take what they wrote
// away again -- so running them twice does what running them once did.

import { exists, readFile, remove, rmdir } from slate:fs

import { keep, pick, safeName, Root } from "../api/uploads.sl"
import { picture, Svg } from "./support.sl"

// A request as `multipart` would have left it.
carrying(files: array) -> object = { form: { fields: {}, files: files } }

// What a test wrote, taken away again.
async swept(what: string, id: integer, name: string)
    await remove(Root + "/" + what + "/" + string(id) + "/" + name)
    await rmdir(Root + "/" + what + "/" + string(id))
    await rmdir(Root + "/" + what)

// -- the name ---------------------------------------------------------------------------------------

@test
A_NAME_IS_LETTERS_DIGITS_AND_THREE_MARKS_AND_EVERYTHING_ELSE_IS_A_DASH()
    assertEq(safeName("square.svg"), "square.svg")
    assertEq(safeName("my photo (1).png"), "my-photo--1-.png")
    assertEq(safeName("a/b\\c.png"), "a-b-c.png")

@test
A_NAME_CANNOT_CLIMB_OUT_OF_WHERE_IT_IS_PUT()
    // **Taking the whole class away rather than looking for the ones already known**: a slash, a
    // backslash, a `..`, a newline and a null are one rule here.
    assertEq(safeName("../../etc/passwd"), "etc-passwd")
    assertEq(safeName("..\\..\\windows\\system32"), "windows-system32")
    assertEq(safeName("....//....//x.png"), "x.png")

@test
A_NAME_THAT_IS_NOTHING_LEFT_IS_STILL_A_NAME()
    assertEq(safeName(""), "photo")
    assertEq(safeName("..."), "photo")
    assertEq(safeName("   "), "photo")

@test
A_NAME_IS_BOUNDED_BECAUSE_A_FILESYSTEM_IS()
    assertEq(len(safeName(repeat("a", 300) + ".png")), 80)

// -- what a form sent --------------------------------------------------------------------------------

@test
A_FILE_INPUT_SOMEBODY_LEFT_ALONE_IS_NOT_A_PHOTO()
    // **A file input a person did not touch still posts a part**, with an empty filename and no
    // content, so "there is no photo" is a thing to test for rather than an absent member.
    assertEq(pick(carrying([{ field: "photo", filename: "", type: "", content: "" }]), "photo"), null)
    assertEq(pick(carrying([]), "photo"), null)
    assertEq(pick({}, "photo"), null)

@test
A_FILE_IS_FOUND_BY_THE_FIELD_IT_WAS_SENT_UNDER()
    val two = carrying([{ field: "other", filename: "a.svg", type: "image/svg+xml", content: "x" },
                        picture("b.svg")])

    assertEq(pick(two, "photo").filename, "b.svg")

// -- the disk ------------------------------------------------------------------------------------------

@test
async A_PHOTO_IS_WRITTEN_UNDER_THE_POST_THAT_OWNS_IT()
    val put = await keep("threads", 4242, picture("square.svg"))

    assert(put.ok, "the write worked")
    assertEq(put.value, "threads/4242/square.svg")

    val back = await readFile(Root + "/" + put.value)

    assert(back.ok)
    assertEq(back.value, Svg)

    await swept("threads", 4242, "square.svg")

    assertEq(await exists(Root + "/threads/4242"), false)

@test
async SOMETHING_THAT_IS_NOT_AN_IMAGE_IS_REFUSED_BEFORE_ANYTHING_IS_WRITTEN()
    val put = await keep("threads", 4243,
        { field: "photo", filename: "run.sh", type: "text/x-shellscript", content: "rm -rf /" })

    assert(!put.ok)
    assertEq(put.status, 415)
    assertEq(await exists(Root + "/threads/4243"), false)

@test
async THE_TYPE_IS_WHAT_THE_CLIENT_CLAIMED_AND_IS_WORTH_EXACTLY_THAT()
    // **A real board sniffs the first bytes as well** -- the magic number of a PNG, a JPEG, a GIF -- and
    // that needs a body this server does not yet hand over as bytes. The header is the check that can
    // be made today, and it is stated as such rather than passed off as more than it is.
    val lying = await keep("threads", 4244,
        { field: "photo", filename: "notreally.png", type: "image/png", content: "this is not a PNG" })

    assert(lying.ok, "a claimed type is taken at its word")

    await swept("threads", 4244, "notreally.png")
