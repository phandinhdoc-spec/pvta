import Foundation

/// Các phương thức có sẵn của lõi (dữ liệu hội thoại, dự án, cài đặt, xuất/nhập).
/// Phương thức ghi phát sự kiện chung `data.changed` để các bên đang nối làm mới.
enum Builtin {
    private static func read(_ name: String, _ body: @escaping @Sendable (DataStore, JSONValue) async throws -> JSONValue)
        -> (String, Core.Handler) {
        (name, { ctx in try await body(ctx.core.store, ctx.params) })
    }

    private static func write(_ name: String, _ body: @escaping @Sendable (DataStore, JSONValue) async throws -> JSONValue)
        -> (String, Core.Handler) {
        (name, { ctx in
            let result = try await body(ctx.core.store, ctx.params)
            ctx.core.broadcast("data.changed", ["method": .string(name)])
            return result
        })
    }

    private static func backend(_ name: String) throws -> CLIBackendID {
        guard let id = CLIBackendID(rawValue: name) else {
            throw PVTAError("Công cụ AI \"\(name)\" không có trong PVTA. Dùng một trong: " + CLIBackendID.allCases.map(\.rawValue).joined(separator: ", ") + ".")
        }
        return id
    }

    /// Ảnh chụp trạng thái cho giao diện: hội thoại (kèm đang bận, số lời lệnh chờ), dự án, cờ việc gấp.
    private static func appView(_ core: Core) async throws -> JSONValue {
        let busy = Set(await core.turns.runningChats())
        var chats: [JSONValue] = []
        for c in try await core.store.chats() {
            guard case .object(var o) = try JSONValue(encoding: c) else { continue }
            o["busy"] = .bool(busy.contains(c.id))
            o["queued"] = .number(Double(try await core.store.queue(chatId: c.id).count))
            chats.append(.object(o))
        }
        return ["version": .string(PVTAInfo.version), "chats": .array(chats), "projects": try JSONValue(encoding: await core.store.projects()),
                "urgency": try JSONValue(encoding: await core.urgency.current())]
    }

    /// Chế độ viết, quy tắc `#khóa`, lời nhắc mẫu `@khóa` và tối ưu lời nhắc.
    private static func writingMethods() -> [(String, Core.Handler)] {
        @Sendable func strings(_ v: JSONValue?) -> [String] { if case .array(let a)? = v { return a.compactMap(\.string) }; return [] }
        @Sendable func values(_ v: JSONValue?) -> [String: String] {
            guard case .object(let o)? = v else { return [:] }
            return o.compactMapValues(\.string)
        }
        @Sendable func changed(_ ctx: CallContext, _ name: String) { ctx.core.broadcast("data.changed", ["method": .string(name)]) }
        return [
            ("mode.list", { ctx in
                ["selected": .string(ctx.core.writing.selectedId()), "defaultId": .string(BuiltinModes.defaultID),
                 "modes": try JSONValue(encoding: await ctx.core.writing.modes())]
            }),
            ("mode.save", { ctx in
                let p = ctx.params
                let id = try await ctx.core.store.saveMode(id: p["id"]?.string, name: p.requireString("name"), icon: p["icon"]?.string, hint: p["hint"]?.string,
                                                           instructions: p.requireString("instructions"), origin: p["origin"]?.string)
                changed(ctx, "mode.save")
                return try JSONValue(encoding: await ctx.core.writing.resolve(id))
            }),
            ("mode.delete", { ctx in
                try await ctx.core.store.deleteMode(id: ctx.params.requireString("id")); changed(ctx, "mode.delete"); return .null
            }),
            ("mode.reorder", { ctx in
                try await ctx.core.store.reorderModes(ids: strings(ctx.params["ids"])); changed(ctx, "mode.reorder"); return .null
            }),
            ("mode.history", { ctx in try JSONValue(encoding: await ctx.core.store.modeHistory(id: ctx.params.requireString("id"))) }),
            ("mode.preview", { ctx in
                try JSONValue(encoding: await ctx.core.store.previewModeBackup(id: ctx.params.requireString("id"), backupId: ctx.params.requireString("backupId")))
            }),
            ("mode.restore", { ctx in
                let p = ctx.params
                try await ctx.core.store.restoreMode(id: p.requireString("id"), backupId: p.requireString("backupId"),
                                                     revision: p.requireString("revision"), backupRevision: p.requireString("backupRevision"))
                changed(ctx, "mode.restore")
                return .null
            }),
            ("mode.select", { ctx in try JSONValue(encoding: await ctx.core.writing.select(ctx.params.requireString("id"))) }),
            ("rule.list", { ctx in
                try JSONValue(encoding: await ctx.core.store.rules(scope: ctx.params["scope"]?.string, scopeId: ctx.params["scopeId"]?.string))
            }),
            ("rule.save", { ctx in
                let p = ctx.params
                let r = try await ctx.core.store.saveRule(id: p["id"]?.string, scope: p["scope"]?.string ?? "profile", scopeId: p["scopeId"]?.string ?? "",
                                                          title: p.requireString("title"), text: p.requireString("text"), always: p["always"]?.bool ?? false)
                changed(ctx, "rule.save")
                return try JSONValue(encoding: r)
            }),
            ("rule.delete", { ctx in
                try await ctx.core.store.deleteRule(id: ctx.params.requireString("id")); changed(ctx, "rule.delete"); return .null
            }),
            ("prompt.list", { ctx in
                let lib = ctx.core.writing.prompts
                return ["categories": try JSONValue(encoding: lib.categories()),
                        "prompts": try JSONValue(encoding: await lib.search(query: ctx.params["query"]?.string ?? "", category: ctx.params["category"]?.string))]
            }),
            ("prompt.save", { ctx in
                let p = ctx.params
                let r = try await ctx.core.store.savePrompt(id: p["id"]?.string, title: p.requireString("title"), text: p.requireString("text"), category: p["category"]?.string)
                changed(ctx, "prompt.save")
                return try JSONValue(encoding: r)
            }),
            ("prompt.delete", { ctx in
                try await ctx.core.store.deletePrompt(id: ctx.params.requireString("id")); changed(ctx, "prompt.delete"); return .null
            }),
            ("prompt.favorite", { ctx in
                try await ctx.core.store.setFavorite(id: ctx.params.requireString("id"), ctx.params["on"]?.bool ?? true); changed(ctx, "prompt.favorite"); return .null
            }),
            ("prompt.fill", { ctx in
                try JSONValue(encoding: await ctx.core.writing.prompts.fill(ref: ctx.params["id"]?.string, text: ctx.params["text"]?.string, values: values(ctx.params["values"])))
            }),
            ("prompt.optimize", { ctx in
                try await ctx.core.track(kind: "prompt.optimize") { try JSONValue(encoding: await ctx.core.writing.prompts.optimize(ctx.params.requireString("text"))) }
            }),
        ]
    }

    private static func powerpoint(_ ctx: CallContext, tool: String) async throws -> JSONValue {
        let chatId = try ctx.params.requireString("chatId")
        guard let spec = ctx.core.files.powerpointToolSpecs.first(where: { $0.name == tool }) else { throw PVTAError("Không tìm thấy công cụ PowerPoint.") }
        switch await PermissionPolicy(ctx.core.permissions).decide(spec, args: ctx.params, chatId: chatId) {
        case .deny(let why): throw PVTAError(why)
        case .allow:
            return try await ctx.core.track(kind: tool, chatId: chatId) { .string(try await spec.run(ctx.params)) }
        }
    }

    static func methods() -> [String: Core.Handler] {
        let list: [(String, Core.Handler)] = [
            ("core.ping", { _ in "pong" }),
            ("core.info", { _ in
                ["pid": .number(Double(ProcessInfo.processInfo.processIdentifier)), "version": .string(PVTAInfo.version)]
            }),
            write("chat.create") { s, p in
                try JSONValue(encoding: await s.createChat(title: p["title"]?.string ?? "Hội thoại mới", projectId: p["projectId"]?.string))
            },
            read("chat.list") { s, _ in try JSONValue(encoding: await s.chats()) },
            read("chat.messages") { s, p in try JSONValue(encoding: await s.messages(chatId: p.requireString("id"))) },
            write("chat.rename") { s, p in
                try await s.renameChat(id: p.requireString("id"), title: p.requireString("title")); return .null
            },
            ("chat.delete", { ctx in
                let id = try ctx.params.requireString("id")
                if await ctx.core.chat.isBusy(id) { throw PVTAError("Hội thoại đang xử lý; hãy dừng yêu cầu rồi mới xóa.") }
                try await ctx.core.store.deleteChat(id: id)
                ctx.core.attachments.removeFiles(chatId: id)
                ctx.core.broadcast("data.changed", ["method": "chat.delete", "chatId": .string(id)])
                return .null
            }),
            write("chat.pin") { s, p in
                try await s.setPinned(id: p.requireString("id"), p["pinned"]?.bool ?? true); return .null
            },
            write("chat.move") { s, p in
                try await s.moveChat(id: p.requireString("id"), toProject: p["projectId"]?.string); return .null
            },
            write("project.create") { s, p in try JSONValue(encoding: await s.createProject(name: p.requireString("name"))) },
            read("project.list") { s, _ in try JSONValue(encoding: await s.projects()) },
            write("project.rename") { s, p in
                try await s.renameProject(id: p.requireString("id"), name: p.requireString("name")); return .null
            },
            write("project.delete") { s, p in try await s.deleteProject(id: p.requireString("id")); return .null },
            read("setting.get") { s, p in try await s.setting(p.requireString("key")).map { .string($0) } ?? .null },
            write("setting.set") { s, p in
                try await s.setSetting(p.requireString("key"), p.requireString("value")); return .null
            },
            read("activity.list") { s, p in
                try JSONValue(encoding: await s.activities(projectId: p["projectId"]?.string,
                                                           limit: Int(p["limit"]?.number ?? 500)))
            },
            read("activity.export") { s, _ in
                ["text": .string(ActivityReport.render(try await s.activities(limit: 500)))]
            },
            ("tools.status", { ctx in
                let env = ctx.core.ai.cli
                let ids = try ctx.params["backend"]?.string.map { [try backend($0)] } ?? CLIBackendID.allCases
                let statuses = await withTaskGroup(of: ToolStatus.self) { group in
                    for id in ids { group.addTask { await ToolHealth.check(id, in: env) } }
                    var out: [ToolStatus] = []
                    for await s in group { out.append(s) }
                    return out
                }
                return try JSONValue(encoding: ids.compactMap { id in statuses.first { $0.id == id } })
            }),
            ("tools.installers", { _ in try JSONValue(encoding: ToolInstaller.catalog) }),
            ("tools.install", { ctx in
                let id = try backend(ctx.params.requireString("backend"))
                return try await ctx.core.track(kind: "tools.install") { try JSONValue(encoding: await ctx.core.setup.install(id)) }
            }),
            ("tools.login", { ctx in
                let id = try backend(ctx.params.requireString("backend"))
                let device = ctx.params["deviceCode"]?.bool ?? false
                return try await ctx.core.track(kind: "tools.login") { try JSONValue(encoding: await ctx.core.setup.login(id, deviceCode: device)) }
            }),
            ("tools.sendCode", { ctx in
                try await ctx.core.setup.sendCode(backend(ctx.params.requireString("backend")), ctx.params.requireString("code"))
                return .null
            }),
            ("tools.cancelSetup", { ctx in
                await ctx.core.setup.cancel(try backend(ctx.params.requireString("backend")))
                return .null
            }),
            ("chat.send", { ctx in
                // `/sign "…"` đi tới Thư ký (hội thoại riêng, khóa lượt riêng): chạy song song, không chờ lượt chat đang bận.
                if let text = ctx.params["text"]?.string, SecretaryService.parseSign(text) != nil {
                    let r = try await ctx.core.track(kind: "secretary.sign") { try await ctx.core.secretary.sign(text, emit: ctx.emit) }
                    var out = try JSONValue(encoding: r)
                    if case .object(var o) = out { o["sign"] = .bool(true); out = .object(o) }
                    return out
                }
                let result = try await ctx.core.chat.send(
                    chatId: ctx.params.requireString("chatId"), text: ctx.params.requireString("text"), model: ctx.params["model"]?.string, mode: ctx.params["mode"]?.string,
                    maxRounds: Int(ctx.params["maxRounds"]?.number ?? Double(ChatLoop.defaultMaxRounds)), emit: ctx.emit)
                return try JSONValue(encoding: result)
            }),
            ("chat.cancel", { ctx in .bool(await ctx.core.chat.cancel(chatId: try ctx.params.requireString("chatId"))) }),
            ("chat.queue", { ctx in
                let (item, started) = try await ctx.core.chat.queue(chatId: ctx.params.requireString("chatId"),
                                                                    text: ctx.params.requireString("text"), mode: ctx.params["mode"]?.string ?? "queue")
                return ["id": .string(item.id), "started": .bool(started)]
            }),
            ("chat.queueList", { ctx in try JSONValue(encoding: await ctx.core.store.queue(chatId: ctx.params.requireString("chatId"))) }),
            ("chat.queueChange", { ctx in
                try await ctx.core.chat.changeQueue(chatId: ctx.params.requireString("chatId"), id: ctx.params["id"]?.string,
                                                    action: ctx.params.requireString("action"), text: ctx.params["text"]?.string)
                return .null
            }),
            read("chat.readDraft") { s, p in .string(try await s.draft(chatId: p.requireString("chatId"))) },
            ("chat.saveDraft", { ctx in
                try await ctx.core.store.saveDraft(chatId: ctx.params.requireString("chatId"), ctx.params["text"]?.string ?? "")
                return .null
            }),
            read("chat.summary") { s, p in
                let (text, covered) = try await s.summary(chatId: p.requireString("chatId"))
                return ["summary": .string(text), "covered": .number(Double(covered))]
            },
            ("chat.saveSummary", { ctx in
                try await ctx.core.chat.saveSummary(chatId: ctx.params.requireString("chatId"), ctx.params["summary"]?.string ?? "")
                return .null
            }),
            ("chat.setModel", { ctx in
                try await ctx.core.chat.setModel(chatId: ctx.params.requireString("chatId"), ctx.params["model"]?.string)
                return .null
            }),
            ("chat.view", { ctx in
                let id = try ctx.params.requireString("chatId")
                let s = ctx.core.store
                guard let chat = try await s.chat(id: id) else { throw PVTAError("Không tìm thấy hội thoại. Có thể nó đã bị xóa.") }
                let (summary, covered) = try await s.summary(chatId: id)
                return ["chat": try JSONValue(encoding: chat), "messages": try JSONValue(encoding: await s.messages(chatId: id)),
                        "queue": try JSONValue(encoding: await s.queue(chatId: id)), "queuePaused": .bool(try await s.queuePaused(chatId: id)),
                        "busy": .bool(await ctx.core.chat.isBusy(id)), "draft": .string(try await s.draft(chatId: id)),
                        "summary": .string(summary), "summaryCovered": .number(Double(covered))]
            }),
            ("attachment.add", { ctx in
                let paths: [String]
                if case .array(let a)? = ctx.params["paths"] { paths = a.compactMap(\.string) } else if let p = ctx.params["path"]?.string { paths = [p] } else { paths = [] }
                guard !paths.isEmpty else { throw PVTAError("Thiếu đường dẫn tệp cần đính kèm (paths).") }
                let r = try await ctx.core.attachments.add(chatId: ctx.params.requireString("chatId"), paths: paths)
                ctx.core.broadcast("data.changed", ["method": "attachment.add", "chatId": ctx.params["chatId"] ?? .null])
                return try JSONValue(encoding: r)
            }),
            ("attachment.remove", { ctx in
                try await ctx.core.attachments.remove(id: ctx.params.requireString("id"))
                ctx.core.broadcast("data.changed", ["method": "attachment.remove"])
                return .null
            }),
            ("attachment.list", { ctx in try JSONValue(encoding: await ctx.core.attachments.list(chatId: ctx.params.requireString("chatId"))) }),
            ("attachment.image", { ctx in
                let img = try await ctx.core.attachments.image(id: ctx.params.requireString("id"))
                return ["name": .string(img.name), "data": .string(AttachmentService.dataURL(img.mime, img.data))]
            }),
            ("attachment.context", { ctx in
                try JSONValue(encoding: await ctx.core.attachments.contextReport(chatId: ctx.params.requireString("chatId"), text: ctx.params["text"]?.string ?? ""))
            }),
            ("file.extractText", { ctx in
                let path = try ctx.params.requireString("path")
                guard path.hasPrefix("/") else { throw PVTAError("Cần đường dẫn tuyệt đối.") }
                return try JSONValue(encoding: TextExtractor.extract(URL(fileURLWithPath: path)))
            }),
            ("file.pathKinds", { ctx in
                guard case .array(let a)? = ctx.params["paths"] else { throw PVTAError("Thiếu danh sách đường dẫn (paths).") }
                let r = AttachmentService.pathKinds(a.compactMap(\.string))
                return ["dirs": .array(r.dirs.map { .string($0) }), "files": .array(r.files.map { .string($0) })]
            }),
            ("file.resolveRef", { ctx in
                let (url, a) = try await ctx.core.attachments.resolve(chatId: ctx.params.requireString("chatId"), ref: ctx.params.requireString("ref"))
                return ["path": .string(url.path), "name": .string(url.lastPathComponent), "attached": .bool(a != nil)]
            }),
            ("file.quickPreview", { ctx in
                try JSONValue(encoding: await ctx.core.attachments.quickPreview(chatId: ctx.params.requireString("chatId"), ref: ctx.params.requireString("ref")))
            }),
            ("file.mediaPreview", { ctx in
                try JSONValue(encoding: await ctx.core.attachments.mediaPreview(chatId: ctx.params.requireString("chatId"), ref: ctx.params.requireString("ref")))
            }),
            ("file.previewRef", { ctx in
                try JSONValue(encoding: await ctx.core.attachments.previewRef(chatId: ctx.params.requireString("chatId"), ref: ctx.params.requireString("ref")))
            }),
            ("source.tree", { ctx in .array(try await ctx.core.attachments.sourceTree(chatId: ctx.params.requireString("chatId"))) }),
            ("source.search", { ctx in
                try JSONValue(encoding: await ctx.core.attachments.sourceSearch(
                    chatId: ctx.params.requireString("chatId"), kind: ctx.params["kind"]?.string == "dir" ? "dir" : "file",
                    query: ctx.params["query"]?.string ?? "", folder: ctx.params["folder"]?.string, limit: Int(ctx.params["limit"]?.number ?? 50)))
            }),
            ("screen.capture", { ctx in
                let mode = ctx.params["mode"]?.string.flatMap(ScreenMode.init(rawValue:)) ?? .selection
                return try JSONValue(encoding: await ctx.core.screen.capture(mode: mode, requestPermission: ctx.params["requestPermission"]?.bool ?? false))
            }),
            ("screen.paste", { ctx in try JSONValue(encoding: ctx.core.screen.paste(dataURL: ctx.params.requireString("dataUrl"))) }),
            ("screen.deliver", { ctx in
                let r = try await ctx.core.screen.deliver(captureId: ctx.params.requireString("captureId"), chatId: ctx.params["chatId"]?.string, folder: ctx.params["folder"]?.string)
                if ctx.params["chatId"]?.string != nil { ctx.core.broadcast("data.changed", ["method": "screen.deliver"]) }
                return r
            }),
            ("screen.scan", { ctx in
                let since = Date(timeIntervalSince1970: ctx.params["since"]?.number ?? Date().timeIntervalSince1970)
                var seen = Set<String>()
                if case .array(let a)? = ctx.params["seen"] { seen = Set(a.compactMap(\.string)) }
                let r = ctx.core.screen.scan(since: since, seen: seen)
                return ["files": try JSONValue(encoding: r.files), "denied": .array(r.denied.map { .string($0) })]
            }),
            ("permission.get", { ctx in try JSONValue(encoding: await ctx.core.permissions.view()) }),
            ("permission.set", { ctx in
                let name = try ctx.params.requireString("level")
                guard let level = PermissionLevel(rawValue: name) else {
                    throw PVTAError("Mức quyền không hợp lệ. Chọn một trong: " + PermissionLevel.allCases.map(\.rawValue).joined(separator: ", ") + ".")
                }
                return try JSONValue(encoding: await ctx.core.permissions.setLevel(level, acknowledge: ctx.params["acknowledge"]?.bool ?? false))
            }),
            ("grant.add", { ctx in
                try JSONValue(encoding: await ctx.core.permissions.addGrant(path: ctx.params.requireString("path"), write: ctx.params["write"]?.bool ?? false))
            }),
            ("grant.remove", { ctx in
                try await ctx.core.permissions.removeGrant(path: ctx.params.requireString("path"))
                return .null
            }),
            ("grant.list", { ctx in try JSONValue(encoding: await ctx.core.store.grants()) }),
            ("action.list", { ctx in try JSONValue(encoding: await ctx.core.permissions.queue.list(chatId: ctx.params["chatId"]?.string)) }),
            ("action.approve", { ctx in
                try await ctx.core.permissions.queue.approve(id: ctx.params.requireString("id"), force: ctx.params["force"]?.bool ?? false)
                return .null
            }),
            ("action.decline", { ctx in
                try await ctx.core.permissions.queue.decline(id: ctx.params.requireString("id"))
                return .null
            }),
            ("edit.open", { ctx in
                try JSONValue(encoding: await ctx.core.files.editOpen(path: ctx.params.requireString("path"), chatId: ctx.params["chatId"]?.string))
            }),
            ("edit.read", { ctx in
                let r = try await ctx.core.files.editRead(sessionId: ctx.params.requireString("sessionId"), start: Int(ctx.params["start"]?.number ?? 0),
                                                          length: ctx.params["length"]?.number.map { Int($0) })
                return ["session": try JSONValue(encoding: r.session), "text": .string(r.text), "total": .number(Double(r.total))]
            }),
            ("edit.apply", { ctx in
                let edits: [TextEdit]? = ctx.params["edits"] == nil ? nil : try TextEdit.parse(ctx.params["edits"])
                return try JSONValue(encoding: await ctx.core.files.editApply(
                    sessionId: ctx.params.requireString("sessionId"), revision: Int(ctx.params["revision"]?.number ?? -1), edits: edits, content: ctx.params["content"]?.string))
            }),
            ("edit.undo", { ctx in
                try JSONValue(encoding: await ctx.core.files.editMove(sessionId: ctx.params.requireString("sessionId"), revision: Int(ctx.params["revision"]?.number ?? -1), by: -1))
            }),
            ("edit.redo", { ctx in
                try JSONValue(encoding: await ctx.core.files.editMove(sessionId: ctx.params.requireString("sessionId"), revision: Int(ctx.params["revision"]?.number ?? -1), by: 1))
            }),
            ("edit.diff", { ctx in .string(try await ctx.core.files.editDiff(sessionId: ctx.params.requireString("sessionId"))) }),
            ("edit.save", { ctx in
                let v = try await ctx.core.files.editSave(sessionId: ctx.params.requireString("sessionId"), revision: Int(ctx.params["revision"]?.number ?? -1),
                                                           destination: ctx.params["path"]?.string, chatId: ctx.params["chatId"]?.string)
                ctx.core.broadcast("data.changed", ["method": "edit.save"])
                return try JSONValue(encoding: v)
            }),
            ("edit.discard", { ctx in
                try await ctx.core.files.editDiscard(sessionId: ctx.params.requireString("sessionId"), revision: Int(ctx.params["revision"]?.number ?? -1))
                return .null
            }),
            ("change.list", { ctx in try JSONValue(encoding: await ctx.core.files.changes(limit: Int(ctx.params["limit"]?.number ?? 50))) }),
            ("change.undo", { ctx in
                let c = try await ctx.core.files.undo(id: ctx.params.requireString("id"))
                ctx.core.broadcast("data.changed", ["method": "change.undo"])
                return try JSONValue(encoding: c)
            }),
            ("output.location", { ctx in
                let id = try ctx.params.requireString("chatId")
                let choices = try await ctx.core.store.grants().filter(\.write).map(\.path)
                return ["dir": try await ctx.core.files.outputDirectory(chatId: id).map { JSONValue.string($0) } ?? .null,
                        "choices": .array(choices.map { .string($0) })]
            }),
            ("output.select", { ctx in
                .string(try await ctx.core.files.selectOutput(chatId: ctx.params.requireString("chatId"), dir: ctx.params.requireString("dir")))
            }),
            ("file.open", { ctx in
                .string(try await ctx.core.files.open(ref: ctx.params.requireString("ref"), chatId: ctx.params["chatId"]?.string, reveal: ctx.params["reveal"]?.bool ?? false))
            }),
            ("powerpoint.read", { ctx in
                .string(try await ctx.core.files.powerpointRead(path: ctx.params.requireString("path"), chatId: ctx.params["chatId"]?.string))
            }),
            ("powerpoint.create", { ctx in try await powerpoint(ctx, tool: "powerpoint_create") }),
            ("powerpoint.edit", { ctx in try await powerpoint(ctx, tool: "powerpoint_edit") }),
            ("typst.export", { ctx in
                try await ctx.core.track(kind: "typst.export", chatId: ctx.params["chatId"]?.string) {
                    try await ctx.core.files.typstExport(ctx.params)
                }
            }),
            ("code.interpreters", { ctx in try JSONValue(encoding: ctx.core.code.interpreters()) }),
            ("code.scan", { ctx in try JSONValue(encoding: CodeScanner.scan(ctx.params.requireString("code"))) }),
            ("code.review", { ctx in
                let req = try CodeRequest(ctx.params)
                return try JSONValue(encoding: await ctx.core.code.review(lang: req.lang, code: req.code, goal: req.goal))
            }),
            ("code.run", { ctx in
                let req = try CodeRequest(ctx.params)
                let r = try await ctx.core.code.runWithApproval(req, chatId: ctx.params.requireString("chatId"))
                return try JSONValue(encoding: r)
            }),
            ("app.view", { ctx in try await appView(ctx.core) }),
            ("app.refresh", { ctx in
                await ctx.core.router.invalidate()
                return try await appView(ctx.core)
            }),
            ("model.resolve", { ctx in
                let kind = ctx.params["kind"]?.string.flatMap(TaskKind.init(rawValue:))
                    ?? TaskClassifier.classify(TaskHints(text: ctx.params["text"]?.string ?? "",
                                                         attachmentNames: ctx.params["attachments"].flatMap { v -> [String]? in
                                                             if case .array(let a) = v { return a.compactMap(\.string) } else { return nil } } ?? []))
                return try JSONValue(encoding: await ctx.core.router.choose(kind: kind))
            }),
            ("usage.read", { ctx in
                let key = try ctx.params.requireString("provider")
                return try JSONValue(encoding: await ctx.core.usage.usage(key, force: ctx.params["force"]?.bool ?? false))
            }),
            ("handoff.list", { ctx in try JSONValue(encoding: await ctx.core.handoffs.views()) }),
            ("handoff.choose", { ctx in
                try await ctx.core.handoffs.choose(id: ctx.params.requireString("id"), model: ctx.params["model"]?.string)
                return .null
            }),
            ("urgency.get", { ctx in try JSONValue(encoding: await ctx.core.urgency.current()) }),
            ("urgency.set", { ctx in
                guard let on = ctx.params["on"]?.bool else { throw PVTAError("Thiếu trạng thái cờ (on: true/false).") }
                return try JSONValue(encoding: await ctx.core.urgency.set(on))
            }),
            ("urgency.limit", { ctx in
                .number(Double(await ctx.core.urgency.limit(requested: Int(ctx.params["requested"]?.number ?? 1))))
            }),
            ("api.status", { ctx in try JSONValue(encoding: ctx.core.ai.status()) }),
            ("api.save", { ctx in
                try ctx.core.ai.save(provider: ctx.params.requireString("provider"),
                                     baseUrl: ctx.params["baseUrl"]?.string, model: ctx.params["model"]?.string)
                ctx.core.broadcast("data.changed", ["method": "api.save"])
                return .null
            }),
            ("api.saveKey", { ctx in
                try ctx.core.ai.saveKey(provider: ctx.params.requireString("provider"), ctx.params.requireString("key"))
                ctx.core.broadcast("data.changed", ["method": "api.saveKey"])
                return .null
            }),
            ("api.deleteKey", { ctx in
                try ctx.core.ai.deleteKey(provider: ctx.params.requireString("provider"))
                ctx.core.broadcast("data.changed", ["method": "api.deleteKey"])
                return .null
            }),
            ("api.models", { ctx in
                try JSONValue(encoding: await ctx.core.ai.listModels(provider: ctx.params.requireString("provider")))
            }),
            ("api.usage", { ctx in try JSONValue(encoding: await ctx.core.ai.meter.snapshot()) }),
            // Gửi một câu hỏi lẻ tới model; chữ đang stream phát qua sự kiện riêng `ai.delta`.
            ("ai.ask", { ctx in
                let model = ctx.params["model"]?.string ?? "auto"
                let prompt = try ctx.params.requireString("prompt")
                let kind = ctx.params["kind"]?.string.flatMap(TaskKind.init(rawValue:)) ?? TaskClassifier.classify(TaskHints(text: prompt))
                let request = ChatRequest(system: ctx.params["system"]?.string,
                                          messages: [ChatMessage(role: .user, content: prompt)],
                                          conversationId: ctx.params["session"]?.string)
                return try await ctx.core.track(kind: "ai.ask", model: model) {
                    var text = ""
                    var usage: TokenUsage?
                    var session: String?
                    var used = model
                    for try await event in ctx.core.chatStream(model: model, kind: kind, request) {
                        switch event {
                        case .text(let t): text += t; ctx.emit("ai.delta", ["text": .string(t)])
                        case .usage(let u): usage = u
                        case .session(let id): session = id
                        case .model(let m): used = m
                        }
                    }
                    if let usage {
                        ctx.core.broadcast("usage", ["model": .string(model), "inputTokens": .number(Double(usage.inputTokens)),
                                                     "outputTokens": .number(Double(usage.outputTokens))])
                    }
                    var out: [String: JSONValue] = ["text": .string(text), "model": .string(used)]
                    if let session { out["session"] = .string(session) }
                    if let usage { out["usage"] = ["inputTokens": .number(Double(usage.inputTokens)), "outputTokens": .number(Double(usage.outputTokens))] }
                    return .object(out)
                }
            }),
            read("data.export") { s, _ in try JSONValue(encoding: await s.exportData()) },
            write("data.import") { s, p in
                guard let data = p["data"] else { throw PVTAError("Thiếu tham số \"data\".") }
                try await s.importData(JSONEncoder().encode(data), replace: p["replace"]?.bool ?? false)
                return .null
            },
        ]
        return Dictionary(list + githubMethods() + mathMethods() + googleMethods() + calendarMethods() + automationMethods() + writingMethods() + pdfMethods() + skillMethods() + docMethods() + learningMethods() + knowledgeMethods() + secretaryMethods() + assessmentMethods() + accountingMethods() + legacyMethods(), uniquingKeysWith: { _, new in new })
    }
}
