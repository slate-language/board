{
    name: "board",
    version: "0.1.0",

    // **A project rather than a package**, so there is no `main` and nothing here is imported by
    // anybody else: `slate server.sl` is how it runs and `slate js client.slx` is how the browser
    // half is built. What the manifest is for is the four packages below.
    dependencies: {
        // The API server: routes, guards, sessions, CSRF, the event hub and the problem documents.
        sluice: { git: "github.com/slate-language/sluice", version: "0.3.0" },
        // The UI framework, rendered twice -- to markup on the server and into the page in a
        // browser. `lath/router` is imported by both halves and `lath/dom` only by the browser one.
        lath: { git: "github.com/slate-language/lath", version: "0.4.0" },
        // PostgreSQL, spoken on the same loop that answers HTTP.
        pg: { git: "github.com/slate-language/pg", version: "0.3.0" },
        // Where a request's log line goes. `sluice`'s `logger` guard hands a sink a record and this
        // package takes one, so there is nothing between them.
        logger: { git: "github.com/slate-language/logger", version: "0.1.0" },
    },
}
