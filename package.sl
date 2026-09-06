{
    name: "board",
    version: "0.2.0",

    // **A project rather than a package**, so there is no `main` and nothing here is imported by
    // anybody else: `slate server.sl` is how it runs and `slate js client.slx` is how the browser
    // half is built. What the manifest is for is the five packages below.
    dependencies: {
        // The API server: routes, guards, sessions, CSRF, the multipart parser, the event hub and
        // the problem documents. **0.4.0 is the floor and it is what makes a photograph possible**:
        // its `multipart` reads `req.bytes`, where 0.3.0's read the body as text and a `.png` was
        // the same value as no body at all. 0.4.1 moved the media type in a refused upload's `415`
        // out of the problem document's own `type` member and into `mediaType`.
        sluice: { git: "github.com/slate-language/sluice", version: "0.5.0" },
        // The UI framework, rendered twice -- to markup on the server and into the page in a
        // browser. `lath/router` is imported by both halves and `lath/dom` only by the browser one.
        // **0.5.1 is what makes this board hydratable**: adjacent text children keep their seam, an
        // empty text child stands for no node in either host, and an attribute whose value is
        // `false` or `null` is written by neither.
        // **0.5.2 AND 0.5.3 ARE WHAT MAKE A HYDRATED PAGE MOVE**: `client.slx` says what following a
        // link means with `navigateWith` and listens for the back button with `onNavigate`, and every
        // control in the header that asks for the query took both of those over as a side effect of
        // asking -- so a click moved the address bar and re-rendered one control while the page sat
        // there, and the back button did nothing at all.
        // **0.6.0 IS WHAT `mortar` 0.3.2 NEEDS**: the theme now lives in an atom rather than the
        // address bar, and `atom`, `useAtom`, `createStore` and `Provider` are 0.6.0's.
        lath: { git: "github.com/slate-language/lath", version: "0.7.0" },
        // The stylesheets, as slate values rather than as a blob of quoted CSS. **0.3.2 MOVED THE
        // THEME FROM THE ADDRESS TO A COOKIE**: it lives in a lath atom now, seeded once per request
        // from `req.cookies.theme` and written back by `Theme` itself through `slate:dom`'s
        // `setCookie` (0.0.34) whenever a reader toggles it -- no `?theme` query and no `/theme`
        // route needed for the ordinary case.
        mortar: { git: "github.com/slate-language/mortar", version: "0.4.3" },
        // PostgreSQL, spoken on the same loop that answers HTTP.
        pg: { git: "github.com/slate-language/pg", version: "0.5.0" },
        // Where a request's log line goes. `sluice`'s `logger` guard hands a sink a record and this
        // package takes one, so there is nothing between them.
        logger: { git: "github.com/slate-language/logger", version: "0.2.0" },
    },
}
