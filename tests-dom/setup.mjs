// A document, for the half of this package that has one.
//
//     npm install
//     NODE_OPTIONS="--import ./tests-dom/setup.mjs" slate test --js tests-dom
//
// **`slate test --js` writes the whole suite into one file and runs `node` on it**, so there is
// nowhere to put a `<script>` and no page to load. `--import` is the seam: node runs this module
// before the program, and slate's runtime takes the page off `globalThis.document` -- once, at the
// top of its own module -- so a document that is there by then is the document the suite renders
// into.
//
// **jsdom rather than a fake document written beside the code it checks, and that is the point.** A
// shim written here would agree with `dom.slx` by construction: every mistake this package, or
// slate's own `js_rt_dom.sysl`, could make about what `setAttribute`, `replaceChildren` or
// `addEventListener` do, the shim would make too, and the run would pass. jsdom is somebody else's
// reading of the same specification and is free to disagree. It is how `mounted` was found.
//
// ## The three things a slate test cannot do, and how they are handed to it
//
// **`slate:dom` is twenty-eight names, and none of them dispatches an event, observes a mutation or
// counts what the browser refused to do.** A slate program has no way to reach a JavaScript global
// -- a builtin is a parameter of the emitted program, not a name taken off `globalThis` -- so those
// three have to arrive through names `slate:dom` already has. They do:
//
// - **`setProperty(node, "lathEvent", spec)` dispatches a real event on that node.** A property
//   assignment on an element is exactly what `setProperty` is, and the setter installed below is an
//   ordinary accessor on `Element.prototype`. `spec` is the type and then the modifiers:
//   `"click"`, `"click meta"`, `"click button=1"`, `"keydown key=Enter"`. jsdom builds the event and
//   jsdom dispatches it; nothing here decides what a click means.
// - **`attribute(byId("lath-probe"), "data-mutations")` is a `MutationObserver`'s count.** The
//   observer watches `document.body`, and the element it writes its count on lives in the HEAD --
//   so publishing a count is not itself a mutation the count would see.
// - **`data-navigations` is how many clicks jsdom was allowed to follow.** jsdom raises
//   *"Not implemented: navigation to another Document"* when a click on an anchor is left alone, so
//   the count of those IS the count of links the router declined -- which is what says the refusals
//   were refusals and not a broken link.
//
// **Two names on `slate:dom` would replace all of it** -- a `dispatch(node, type, init)` and an
// `observe(node, fn)` -- and until they exist this is the seam. It does not fake anything: every
// answer above is jsdom's own.

let JSDOM
let VirtualConsole

try {
    const jsdom = await import("jsdom")

    JSDOM = jsdom.JSDOM
    VirtualConsole = jsdom.VirtualConsole
} catch (e) {
    console.error("jsdom is not installed: run npm install")
    process.exit(1)
}

let navigations = 0

// **jsdom's own console, intercepted rather than silenced.** A navigation it would not perform is
// the thing the router tests measure, so it is counted here and kept off the terminal; anything else
// jsdom has to say is passed straight through, because a real error swallowed by a harness is how a
// suite goes quietly green.
const console_ = new VirtualConsole()

console_.on("jsdomError", (e) => {
    const said = String(e && e.message ? e.message : e)

    if (said.includes("Not implemented: navigation")) {
        navigations += 1

        publish()

        return
    }

    console.error(said)
})

for (const kind of ["log", "info", "warn", "error", "dir", "table", "trace"])
    console_.on(kind, (...parts) => console[kind === "dir" ? "log" : kind](...parts))

const dom = new JSDOM(
    "<!doctype html><html><head></head><body><div id=\"page\"></div></body></html>",
    { url: "https://example.test/", virtualConsole: console_ })

const w = dom.window
const doc = w.document

// Where the counts are published. **In the HEAD on purpose**: the observer watches the body, so a
// count written anywhere under it would be a mutation the next read counted.
const probe = doc.createElement("meta")

probe.id = "lath-probe"

doc.head.appendChild(probe)

let records = 0
let touched = 0
let prevented = false

const publish = () => {
    probe.setAttribute("data-mutations", String(records))
    probe.setAttribute("data-touched", String(touched))
    probe.setAttribute("data-navigations", String(navigations))
    probe.setAttribute("data-prevented", prevented ? "true" : "false")
}

publish()

// **`data-mutations` counts RECORDS and `data-touched` counts nodes**, and the pair is the whole
// measurement. A hydrated page has to record nothing at all, which only the first can say; a reorder
// that replaces a whole child list makes one record and moves a thousand nodes, which only the
// second can.
const observer = new w.MutationObserver((rs) => {
    for (const r of rs) {
        records += 1

        if (r.type === "childList")
            touched += r.addedNodes.length + r.removedNodes.length
        else
            touched += 1
    }

    publish()
})

observer.observe(doc.body, { childList: true, attributes: true, characterData: true, subtree: true })

// An event dispatched on the node the property was set on. See the note at the top: this is the one
// way a slate program can make a browser do something a person would have done.
Object.defineProperty(w.Element.prototype, "lathEvent", {
    configurable: true,

    set(spec) {
        const parts = String(spec).split(" ").filter((p) => p !== "")
        const type = parts.shift() ?? "click"
        const init = { bubbles: true, cancelable: true }

        let key = ""

        for (const part of parts) {
            if (part === "meta") init.metaKey = true
            else if (part === "ctrl") init.ctrlKey = true
            else if (part === "shift") init.shiftKey = true
            else if (part === "alt") init.altKey = true
            else if (part.startsWith("button=")) init.button = Number(part.slice(7))
            else if (part.startsWith("key=")) key = part.slice(4)
        }

        let event

        if (type === "click" || type.startsWith("mouse")) {
            if (init.button === undefined) init.button = 0

            event = new w.MouseEvent(type, init)
        } else if (type.startsWith("key")) {
            event = new w.KeyboardEvent(type, { ...init, key: key })
        } else {
            event = new w.Event(type, init)
        }

        this.dispatchEvent(event)

        prevented = event.defaultPrevented

        publish()
    }
})

// The names slate's runtime looks for, and the classes a page has. **`addEventListener` has to be
// the WINDOW's**: node's global is an `EventTarget` of its own, so leaving it alone would register
// `popstate` on something the page never raises one on.
const install = (name, value) => {
    try {
        Object.defineProperty(globalThis, name,
            { value: value, writable: true, configurable: true, enumerable: true })
    } catch (e) {
        globalThis[name] = value
    }
}

install("window", w)
install("document", doc)
install("location", w.location)
install("history", w.history)
install("localStorage", w.localStorage)
install("Node", w.Node)
install("Element", w.Element)
install("HTMLElement", w.HTMLElement)
install("MutationObserver", w.MutationObserver)
install("MouseEvent", w.MouseEvent)
install("KeyboardEvent", w.KeyboardEvent)
install("Event", w.Event)
install("addEventListener", w.addEventListener.bind(w))
install("removeEventListener", w.removeEventListener.bind(w))
install("dispatchEvent", w.dispatchEvent.bind(w))
