import AppKit
import SwiftUI
import Combine

// ────────────────────────────────────────────────────────────────
// Modèle
// ────────────────────────────────────────────────────────────────

enum Status: Int, Comparable {
    case running = 0   // Claude travaille
    case waiting = 1   // Claude a fini, il t'attend
    case idle    = 2   // en pause

    static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .running: return "en cours"
        case .waiting: return "à toi"
        case .idle:    return "en pause"
        }
    }
    var color: Color {
        switch self {
        case .running: return Color(red: 0.31, green: 0.84, blue: 0.53)
        case .waiting: return Color(red: 1.00, green: 0.63, blue: 0.24)
        case .idle:    return Color(white: 0.55)
        }
    }
}

struct Row: Identifiable, Equatable {
    let id: String
    var title: String
    var project: String
    var status: Status
    var detail: String
    var prompt: String
    var date: Date
    var link: String          // claude://… ouvre la discussion dans l'app
}

// ────────────────────────────────────────────────────────────────
// Sources de données
//
//  1. Le registre de l'app  ~/Library/Application Support/Claude/
//     claude-code-sessions/<compte>/<orga>/local_*.json
//     → titre officiel, dossier, session archivée ou non, et surtout
//       l'identifiant `sessionId` qui sert au lien « ouvrir dans Claude ».
//       `cliSessionId` fait le pont vers le fichier transcript.
//
//  2. Le transcript  ~/.claude/projects/<projet>/<cliSessionId>.jsonl
//     → l'état d'avancement (en cours / à toi / en pause) et le détail.
// ────────────────────────────────────────────────────────────────

struct Meta {
    let sessionId: String        // local_xxxx — sert au lien profond
    let cliSessionId: String     // nom du fichier transcript
    let cwd: String
    let title: String
    let archived: Bool
}

struct Progress {
    let status: Status
    let detail: String
    let prompt: String
    let date: Date
}

enum Scan {

    // ⚙️  Réglages — modifie ces deux valeurs puis relance ./build.sh
    static let maxAgeDays: Double = 14     // fenêtre d'affichage (jours)
    static let maxRows = 14                // nombre max de lignes

    // Les dates de modification des fichiers ne sont pas fiables (migrations),
    // on s'en sert juste pour éviter d'ouvrir des transcripts très anciens.
    static let prefilterDays: Double = 120
    static let tailBytes = 400_000         // on ne lit que la fin des transcripts

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let home = FileManager.default.homeDirectoryForCurrentUser

    // Les fiches du registre pèsent ~350 Ko : on ne les relit que si elles changent.
    private static var metaCache: [String: (stamp: Date, meta: Meta?)] = [:]

    // ── Registre de l'app ────────────────────────────────────────

    private static func registry() -> [Meta] {
        let root = home.appendingPathComponent(
            "Library/Application Support/Claude/claude-code-sessions")
        let fm = FileManager.default
        guard let walk = fm.enumerator(at: root,
                                       includingPropertiesForKeys: [.contentModificationDateKey],
                                       options: [.skipsHiddenFiles]) else { return [] }
        var out: [Meta] = []
        for case let url as URL in walk {
            let name = url.lastPathComponent
            guard name.hasPrefix("local_"), name.hasSuffix(".json") else { continue }
            let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if let hit = metaCache[url.path], hit.stamp == stamp {
                if let m = hit.meta { out.append(m) }
                continue
            }
            let meta = readMeta(url)
            metaCache[url.path] = (stamp, meta)
            if let m = meta { out.append(m) }
        }
        return out
    }

    private static func readMeta(_ url: URL) -> Meta? {
        guard let data = try? Data(contentsOf: url),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sid = o["sessionId"] as? String,
              let cli = o["cliSessionId"] as? String else { return nil }
        return Meta(sessionId: sid,
                    cliSessionId: cli,
                    cwd: (o["cwd"] as? String) ?? (o["originCwd"] as? String) ?? "",
                    title: (o["title"] as? String) ?? "",
                    archived: (o["isArchived"] as? Bool) ?? false)
    }

    // ── Transcripts ──────────────────────────────────────────────

    private static func transcripts() -> [String: URL] {
        let root = home.appendingPathComponent(".claude/projects")
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root,
                                                     includingPropertiesForKeys: nil) else { return [:] }
        var idx: [String: URL] = [:]
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(at: dir,
                                                          includingPropertiesForKeys: nil) else { continue }
            for f in files where f.pathExtension == "jsonl" {
                idx[f.deletingPathExtension().lastPathComponent] = f
            }
        }
        return idx
    }

    // ── Assemblage ───────────────────────────────────────────────

    struct Result {
        let rows: [Row]
        let hiddenCount: Int
    }

    /// `hidden` associe un sessionId à la date d'activité au moment du masquage.
    /// Si la discussion a bougé depuis, elle réapparaît d'elle-même.
    static func run(hidden: [String: Date] = [:]) -> Result {
        let idx = transcripts()
        var hiddenCount = 0
        let cutoff = Date().addingTimeInterval(-maxAgeDays * 86_400)
        let prefilter = Date().addingTimeInterval(-prefilterDays * 86_400)
        var rows: [Row] = []

        for meta in registry() where !meta.archived {
            guard let file = idx[meta.cliSessionId] else { continue }
            let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard mtime > prefilter else { continue }
            guard let p = progress(file: file, mtime: mtime) else { continue }
            // On filtre sur la date réelle du dernier message, pas sur le fichier.
            guard p.date > cutoff else { continue }

            if let since = hidden[meta.sessionId], p.date <= since {
                hiddenCount += 1      // masquée, et rien de neuf depuis
                continue
            }

            var title = meta.title.trimmingCharacters(in: .whitespaces)
            if title.isEmpty { title = p.prompt.isEmpty ? "Sans titre" : String(p.prompt.prefix(48)) }
            let project = URL(fileURLWithPath: meta.cwd).lastPathComponent
                .trimmingCharacters(in: .whitespaces)

            rows.append(Row(id: meta.sessionId,
                            title: clean(title),
                            project: project.isEmpty ? "—" : project,
                            status: p.status,
                            detail: p.detail,
                            prompt: p.prompt,
                            date: p.date,
                            link: "claude://claude.ai/epitaxy/" + meta.sessionId))
        }

        rows.sort {
            if $0.status != $1.status { return $0.status < $1.status }
            return $0.date > $1.date
        }
        return Result(rows: Array(rows.prefix(maxRows)), hiddenCount: hiddenCount)
    }

    // Lit uniquement la fin du fichier (certains transcripts font 40 Mo)
    private static func tail(_ path: String) -> (String, Bool) {
        guard let fh = FileHandle(forReadingAtPath: path) else { return ("", false) }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let truncated = size > UInt64(tailBytes)
        let start = truncated ? size - UInt64(tailBytes) : 0
        try? fh.seek(toOffset: start)
        let data = (try? fh.readToEnd()) ?? Data()
        return (String(decoding: data, as: UTF8.self), truncated)
    }

    private static func progress(file: URL, mtime: Date) -> Progress? {
        let (text, truncated) = tail(file.path)
        guard !text.isEmpty else { return nil }
        var lines = text.split(separator: "\n").map(String.init)
        if truncated && !lines.isEmpty { lines.removeFirst() }   // 1re ligne coupée

        var prompt: String?
        var lastMsg: (role: String, types: [String], text: String, tool: String?, date: Date)?

        for line in lines.reversed() {
            if prompt != nil && lastMsg != nil { break }
            guard line.count < 2_000_000,
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = obj["type"] as? String else { continue }

            switch type {
            case "last-prompt":
                if prompt == nil, let p = obj["lastPrompt"] as? String { prompt = clean(p) }
            case "user", "assistant":
                if lastMsg == nil {
                    if let sc = obj["isSidechain"] as? Bool, sc { continue }   // sous-agent
                    let msg = obj["message"] as? [String: Any]
                    let info = blocks(msg?["content"])
                    guard !info.types.isEmpty else { continue }
                    let d = (obj["timestamp"] as? String).flatMap { iso.date(from: $0) } ?? mtime
                    lastMsg = (type, info.types, info.text, info.tool, d)
                }
            default:
                continue
            }
        }

        let stamp = lastMsg?.date ?? mtime
        let age = Date().timeIntervalSince(stamp)
        var status: Status
        var detail: String

        if let m = lastMsg {
            let turnFinished = (m.role == "assistant"
                                && m.types.contains("text")
                                && !m.types.contains("tool_use"))
            if turnFinished {
                status = age < 48 * 3600 ? .waiting : .idle
                detail = m.text.isEmpty ? "Réponse envoyée." : m.text
            } else if age < 300 {
                status = .running
                if let t = m.tool { detail = "→ " + t }
                else if m.types.contains("thinking") { detail = "réfléchit…" }
                else if m.types.contains("tool_result") { detail = "traite le résultat…" }
                else { detail = "au travail…" }
            } else {
                status = .idle
                detail = m.text.isEmpty ? (m.tool.map { "interrompu pendant : " + $0 } ?? "interrompu") : m.text
            }
        } else {
            status = .idle
            detail = prompt ?? ""
        }

        return Progress(status: status,
                        detail: clip(clean(detail), 220),
                        prompt: clip(prompt ?? "", 260),
                        date: stamp)
    }

    // content peut être une String ou un tableau de blocs
    private static func blocks(_ content: Any?) -> (types: [String], text: String, tool: String?) {
        if let s = content as? String {
            return (s.isEmpty ? [] : ["text"], s, nil)
        }
        guard let arr = content as? [[String: Any]] else { return ([], "", nil) }
        var types: [String] = []
        var text = ""
        var tool: String?
        for b in arr {
            guard let t = b["type"] as? String else { continue }
            types.append(t)
            if t == "text", let v = b["text"] as? String, !v.isEmpty, text.isEmpty { text = v }
            if t == "tool_use", tool == nil {
                let name = (b["name"] as? String) ?? "outil"
                if let input = b["input"] as? [String: Any],
                   let desc = input["description"] as? String, !desc.isEmpty {
                    tool = "\(name) · \(desc)"
                } else if let input = b["input"] as? [String: Any],
                          let pa = (input["file_path"] ?? input["path"]) as? String {
                    tool = "\(name) · \(URL(fileURLWithPath: pa).lastPathComponent)"
                } else {
                    tool = name
                }
            }
        }
        return (types, text, tool)
    }

    private static let linkRE = try? NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\([^)]*\\)")

    /// Aplatit le Markdown : [texte](lien) → texte, puis retire ** ` # et les sauts de ligne.
    private static func clean(_ s: String) -> String {
        var t = s
        if let re = linkRE {
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t),
                                            withTemplate: "$1")
        }
        t = t.replacingOccurrences(of: "\n", with: " ")
             .replacingOccurrences(of: "\t", with: " ")
             .replacingOccurrences(of: "**", with: "")
             .replacingOccurrences(of: "`", with: "")
             .replacingOccurrences(of: "### ", with: "")
             .replacingOccurrences(of: "## ", with: "")
             .replacingOccurrences(of: "# ", with: "")
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clip(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n)) + "…"
    }
}

func relative(_ d: Date) -> String {
    let s = Date().timeIntervalSince(d)
    if s < 60 { return "à l'instant" }
    if s < 3600 { return "il y a \(Int(s / 60)) min" }
    if s < 86_400 { return "il y a \(Int(s / 3600)) h" }
    let j = Int(s / 86_400)
    return j == 1 ? "hier" : "il y a \(j) j"
}

// ────────────────────────────────────────────────────────────────
// État
// ────────────────────────────────────────────────────────────────

final class Store: ObservableObject {
    @Published var rows: [Row] = []
    @Published var collapsed = false { didSet { resize?() } }
    @Published var contentHeight: CGFloat = 0 { didSet { resize?() } }
    @Published var quote: String = Quotes.today()
    @Published private(set) var hiddenCount = 0

    /// sessionId → date d'activité au moment où on l'a masquée.
    private var hidden: [String: Date] = [:]
    private let hiddenKey = "hiddenSessions"

    var resize: (() -> Void)?
    private var timer: Timer?
    private let queue = DispatchQueue(label: "scan", qos: .utility)

    init() {
        let raw = UserDefaults.standard.dictionary(forKey: hiddenKey) as? [String: Double] ?? [:]
        hidden = raw.mapValues { Date(timeIntervalSince1970: $0) }
    }

    /// Masque une discussion. Elle revient toute seule si Claude y réécrit.
    func hide(_ row: Row) {
        hidden[row.id] = row.date
        UserDefaults.standard.set(hidden.mapValues { $0.timeIntervalSince1970 },
                                  forKey: hiddenKey)
        refresh()
    }

    func restoreAll() {
        hidden.removeAll()
        UserDefaults.standard.removeObject(forKey: hiddenKey)
        refresh()
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        let snapshot = hidden
        queue.async {
            let r = Scan.run(hidden: snapshot)
            let q = Quotes.today()
            DispatchQueue.main.async {
                if r.rows != self.rows { self.rows = r.rows }
                if r.hiddenCount != self.hiddenCount { self.hiddenCount = r.hiddenCount }
                if q != self.quote { self.quote = q }
            }
        }
    }

}

// ────────────────────────────────────────────────────────────────
// Vue
// ────────────────────────────────────────────────────────────────

/// Remonte la hauteur naturelle de la liste pour que la fenêtre s'y ajuste.
struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    func measureHeight() -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: HeightKey.self, value: g.size.height)
        })
    }
}

struct Blur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// Mascotte pixel art. Si un fichier `mascot.png` est posé à côté de
/// l'exécutable, il est utilisé à la place du dessin ci-dessous.
struct Mascot: View {
    static let art = [
        "...#####...",
        "..#######..",
        ".#########.",
        ".##.###.##.",
        ".##.###.##.",
        ".#########.",
        ".#########.",
        ".#.#.#.#.#.",
        "#..#...#..#"
    ]
    static let cols: CGFloat = 11
    static let rows: CGFloat = 9
    static let orange = Color(red: 0.87, green: 0.46, blue: 0.27)

    /// Cherche mascot.png dans les Resources de l'app, à côté de l'app,
    /// et à côté de l'exécutable — le premier trouvé gagne.
    static let custom: NSImage? = {
        var places: [URL] = []
        if let r = Bundle.main.resourceURL { places.append(r) }
        places.append(Bundle.main.bundleURL.deletingLastPathComponent())
        if let e = Bundle.main.executableURL?.deletingLastPathComponent() { places.append(e) }
        for dir in places {
            let f = dir.appendingPathComponent("mascot.png")
            if FileManager.default.fileExists(atPath: f.path),
               let img = NSImage(contentsOf: f) { return img }
        }
        return nil
    }()

    var unit: CGFloat = 1.45

    var body: some View {
        let w = Mascot.cols * unit, h = Mascot.rows * unit
        Group {
            if let img = Mascot.custom {
                Image(nsImage: img)
                    .interpolation(.none)          // garde les pixels nets
                    .resizable()
                    .scaledToFit()
                    .frame(width: w + 2, height: w + 2)
            } else {
                Canvas { ctx, size in
                    let u = min(size.width / Mascot.cols, size.height / Mascot.rows)
                    for (y, line) in Mascot.art.enumerated() {
                        for (x, ch) in line.enumerated() where ch == "#" {
                            let r = CGRect(x: CGFloat(x) * u, y: CGFloat(y) * u,
                                           width: u, height: u)
                            ctx.fill(Path(r), with: .color(Mascot.orange))
                        }
                    }
                }
                .frame(width: w, height: h)
            }
        }
    }
}

struct Dot: View {
    let status: Status
    @State private var on = false
    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: 7, height: 7)
            .opacity(status == .running ? (on ? 0.35 : 1) : 1)
            .animation(status == .running
                       ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                       : .default, value: on)
            .onAppear { if status == .running { on = true } }
            .padding(.top, 4)
    }
}

/// Bouton orange : ouvre la discussion dans l'app Claude (lien claude://).
struct OpenButton: View {
    let link: String
    @State private var hover = false

    private let orange = Color(red: 0.94, green: 0.45, blue: 0.16)

    var body: some View {
        Button {
            if let u = URL(string: link) { NSWorkspace.shared.open(u) }
        } label: {
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .heavy))
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(orange)
                        .shadow(color: orange.opacity(hover ? 0.7 : 0.3),
                                radius: hover ? 6 : 2)
                )
                .scaleEffect(hover ? 1.08 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .help("Ouvrir cette discussion dans Claude")
    }
}

/// Croix discrète : retire la discussion du widget. Placée à GAUCHE de la
/// flèche orange, qui reste ainsi exactement au même endroit.
struct HideButton: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.primary.opacity(hover ? 0.95 : 0.5))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(hover ? 0.16 : 0.07))
                )
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .help("Masquer cette discussion. Elle revient si Claude y réécrit.")
    }
}

/// Une ligne : titre + flèche. Le détail n'apparaît qu'au survol.
struct RowView: View {
    let row: Row
    let onHide: () -> Void
    @State private var hover = false

    var body: some View {
        // .top et non .center : sinon le bouton se recentre quand la carte
        // s'ouvre au survol, et fuit sous le curseur au moment où on le vise.
        HStack(alignment: .top, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Dot(status: row.status)
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)

                    if hover {
                        HStack(spacing: 5) {
                            Text(row.project)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.primary.opacity(0.45))
                            Text(row.status.label)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(row.status.color.opacity(0.95))
                            Spacer(minLength: 4)
                            Text(relative(row.date))
                                .font(.system(size: 9))
                                .foregroundColor(.primary.opacity(0.4))
                                .fixedSize()
                        }
                        Text(row.detail)
                            .font(.system(size: 11))
                            .foregroundColor(.primary.opacity(0.72))
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                        if !row.prompt.isEmpty {
                            Divider().opacity(0.25).padding(.vertical, 1)
                            Text("Ta demande · " + row.prompt)
                                .font(.system(size: 10))
                                .foregroundColor(.primary.opacity(0.5))
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.top, 4.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            if hover { HideButton(action: onHide) }
            OpenButton(link: row.link)
        }
        .padding(.leading, 9)
        .padding(.trailing, 7)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(hover ? 0.10 : 0.05))
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

struct Panel: View {
    @ObservedObject var store: Store
    @State private var overPanel = false

    var body: some View {
        VStack(spacing: 0) {
            // En-tête (zone de déplacement de la fenêtre)
            HStack(spacing: 7) {
                Mascot()
                Text("Claude")
                    .font(.system(size: 12, weight: .bold))
                    .fixedSize()
                Text(store.quote)
                    .font(.system(size: 10, weight: .medium))
                    .italic()
                    .foregroundColor(.primary.opacity(0.52))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)   // les plus longues se resserrent
                    .help("Le message change chaque matin")
                Spacer(minLength: 2)
                Button { store.collapsed.toggle() } label: {
                    Image(systemName: store.collapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundColor(.primary.opacity(0.45))
                Button { NSApp.terminate(nil) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundColor(.primary.opacity(0.45))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)

            if !store.collapsed {
                Divider().opacity(0.2)
                ScrollView {
                    VStack(spacing: 4) {
                        if store.rows.isEmpty {
                            Text("Aucune discussion récente.")
                                .font(.system(size: 11))
                                .foregroundColor(.primary.opacity(0.45))
                                .padding(.vertical, 18)
                                .frame(maxWidth: .infinity)
                        } else {
                            ForEach(store.rows) { row in
                                RowView(row: row) { store.hide(row) }
                            }
                        }

                        // Rattrapage, visible seulement quand la souris est sur
                        // le widget : ajouté en bas, il ne décale aucune ligne.
                        if overPanel && store.hiddenCount > 0 {
                            HStack(spacing: 5) {
                                Spacer()
                                Text(store.hiddenCount == 1
                                     ? "1 discussion masquée"
                                     : "\(store.hiddenCount) discussions masquées")
                                    .font(.system(size: 9))
                                    .foregroundColor(.primary.opacity(0.4))
                                Button("Tout réafficher") { store.restoreAll() }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(Color(red: 0.94, green: 0.45, blue: 0.16))
                                Spacer()
                            }
                            .padding(.top, 3)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 7)
                    .measureHeight()
                }
            }
        }
        .onHover { overPanel = $0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onPreferenceChange(HeightKey.self) { h in
            if abs(h - store.contentHeight) > 0.5 { store.contentHeight = h }
        }
        .background(Blur().ignoresSafeArea())
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }
}

// ────────────────────────────────────────────────────────────────
// Fenêtre
// ────────────────────────────────────────────────────────────────

/// Sans ça, le premier clic dans une fenêtre inactive sert seulement à la
/// sélectionner : le bouton orange demanderait deux clics.
final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    required init(rootView: Content) { super.init(rootView: rootView) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

final class Delegate: NSObject, NSApplicationDelegate {
    var panel: NSPanel!
    var host: ClickThroughHostingView<Panel>!
    let store = Store()
    private let headerHeight: CGFloat = 35   // barre de titre du widget
    private let maxHeight: CGFloat = 520     // au-delà, la liste défile
    private var startHeight: CGFloat { headerHeight + 120 }

    func applicationDidFinishLaunching(_ note: Notification) {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 390, height: startHeight),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered, defer: false)
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isMovableByWindowBackground = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        let h = ClickThroughHostingView(rootView: Panel(store: store))
        h.autoresizingMask = [.width, .height]
        p.contentView = h
        host = h
        p.setFrameAutosaveName("ClaudeWidgetPanel")
        // La position mémorisée peut dater d'une version plus étroite.
        if p.frame.width != 390 {
            var f = p.frame
            f.size.width = 390
            p.setFrame(f, display: false)
        }
        if p.frame.origin == .zero, let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.maxX - 410, y: f.maxY - startHeight - 12))
        }
        p.orderFrontRegardless()
        panel = p

        store.resize = { [weak self] in self?.applyHeight() }
        store.start()
    }

    /// La fenêtre épouse la hauteur de la liste, plafonnée à maxHeight.
    private func applyHeight() {
        guard let p = panel else { return }
        let target: CGFloat = store.collapsed
            ? headerHeight
            : min(headerHeight + 1 + store.contentHeight, maxHeight)
        guard abs(p.frame.height - target) > 0.5 else { return }
        var f = p.frame
        f.origin.y += f.height - target     // on garde le bord haut fixe
        f.size.height = target
        p.setFrame(f, display: true, animate: false)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
