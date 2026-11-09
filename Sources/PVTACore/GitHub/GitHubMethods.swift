import Foundation

extension Builtin {
    static func githubMethods() -> [(String, Core.Handler)] {
        [
            ("github.catalog", { c in await c.core.github.catalog() }),
            ("github.status", { c in try await c.core.github.status() }),
            ("github.login", { c in try await c.core.github.login(token: c.params.requireString("token"), confirmed: c.params["confirmed"]?.bool == true) }),
            ("github.logout", { c in try await c.core.github.logout(); return .null }),
            ("github.setProjectFolder", { c in try JSONValue(encoding: await c.core.github.link(project: c.params.requireString("projectId"), folder: c.params.requireString("folder"), repository: c.params.requireString("repository"), branch: c.params.requireString("branch"), confirmed: c.params["confirmed"]?.bool == true)) }),
            ("github.preview", { c in try await c.core.github.preview(c.params) }),
            ("github.run", { c in try await c.core.github.run(c.params) }),
            ("github.cancel", { c in ["accepted": .bool(await c.core.github.cancel(try c.params.requireString("runId")))] }),
            ("github.runStatus", { c in try await c.core.github.runStatus(c.params.requireString("runId")) }),
            ("github.journal", { c in try await c.core.github.journal(project: c.params["projectId"]?.string) }),
            ("github.uploadHistory", { c in try await c.core.github.journal(project: c.params["projectId"]?.string, uploads: true) })
        ]
    }
}
