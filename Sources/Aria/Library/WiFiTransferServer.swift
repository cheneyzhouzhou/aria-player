#if os(iOS)
import Foundation
import Network
import UIKit

/// One file sitting in the upload folder.
struct UploadedFile: Identifiable, Hashable {
    let url: URL
    let name: String
    let size: Int64
    let added: Date

    var id: String { url.path }

    /// A lyric sidecar. It belongs beside its song, so it is allowed through the
    /// same drop-box even though the library never turns it into a track.
    var isLyric: Bool { name.lowercased().hasSuffix(".lrc") }
}

/// A tiny drop-box for getting music onto the phone over Wi-Fi.
///
/// Everything here is hand-written on `Network.framework`. The project has no
/// third-party dependencies, and a phone needs exactly one route and one small
/// page here — not a general-purpose web server. The page is plain HTML with a
/// few lines of JavaScript so the desktop only needs a browser.
///
/// Files land in `Documents/Wi-Fi Uploads`, which the settings page registers as
/// a library folder, so anything dropped in shows up in the library immediately.
@MainActor
final class WiFiTransferServer: ObservableObject {
    static let shared = WiFiTransferServer()

    @Published private(set) var isRunning = false
    /// `http://192.168.1.23:8080/abcd/` — includes the one-time path code.
    @Published private(set) var urlString: String?
    @Published private(set) var savedCount = 0
    @Published private(set) var lastName: String?
    /// How many files the upload folder holds right now. Refreshed when the
    /// server starts, after every batch, and whenever the settings page or the
    /// list appears — the folder can also change from the Files app.
    @Published private(set) var storedCount = 0
    @Published private(set) var errorMessage: String?

    /// Called once per finished upload so the library can rescan.
    var onBatchFinished: (() -> Void)?

    let folder: URL = {
        let docs = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
        return docs.appendingPathComponent("Wi-Fi Uploads", isDirectory: true)
    }()

    private var listener: NWListener?
    /// Live connections. Without this the handler would be deallocated the
    /// moment `accept` returns and the request would never be read.
    private var connections: [UUID: TransferConnection] = [:]
    private var triedFallbackPort = false
    private var backgroundObserver: NSObjectProtocol?
    private let queue = DispatchQueue(label: "com.example.aria.wifi-transfer")

    private init() {
        // iOS tears the listener down with the app; stopping first keeps the
        // "running" toggle from lying when the user comes back.
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
    }

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        errorMessage = nil
        savedCount = 0
        lastName = nil

        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        do {
            // 8080 is what people expect and what the old CocoaHTTPServer apps
            // used; if it is taken, `stateUpdateHandler` retries on any free port.
            let listener = try NWListener(using: parameters,
                                          on: NWEndpoint.Port(rawValue: 8080)!)
            attempted(listener)
        } catch {
            errorMessage = L("Couldn’t start the server.")
            return
        }

        // The screen must stay awake: iOS suspends the app — and with it the
        // listener — as soon as it locks or goes to the background.
        UIApplication.shared.isIdleTimerDisabled = true
        isRunning = true
        refreshStored()
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        urlString = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func attempted(_ listener: NWListener) {
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.handle(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            // The handler runs on `queue`; the page and the strings it needs are
            // built on the main actor, so hop over before accepting.
            Task { @MainActor in self.accept(connection) }
        }
        listener.start(queue: queue)
    }

    private func handle(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener?.port?.rawValue else { return }
            urlString = "http://\(Self.localIPv4Address() ?? "127.0.0.1"):\(port)/"
            errorMessage = nil
        case .failed(let error):
            // Port already in use: ask the system for any free one, once.
            if !triedFallbackPort {
                triedFallbackPort = true
                listener?.cancel()
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true
                if let fallback = try? NWListener(using: parameters) {
                    attempted(fallback)
                    return
                }
            }
            errorMessage = error.localizedDescription
            stop()
        default:
            break
        }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        let page = buildPage()
        let id = UUID()
        let handler = TransferConnection(
            connection: connection,
            basePath: "/",
            folder: folder,
            page: page,
            notFoundPage: wrongAddressPage(),
            fallbackName: L("Untitled"),
            queue: queue,
            onSaved: { [weak self] names in
                Task { @MainActor in
                    guard !names.isEmpty else { return }
                    self?.savedCount += names.count
                    self?.lastName = names.last
                    self?.refreshStored()
                    self?.onBatchFinished?()
                }
            },
            onClosed: { [weak self] in
                Task { @MainActor in self?.connections[id] = nil }
            })
        connections[id] = handler
        handler.start()
    }

    private func wrongAddressPage() -> Data {
        Data("""
        <!doctype html><meta charset="utf-8">
        <body style="font:15px -apple-system,sans-serif;padding:40px;line-height:1.6">
        \(L("This address is not the upload page. Use the address shown in Aria › Settings › Wi-Fi transfer."))
        </body>
        """.utf8)
    }

    // MARK: Upload folder

    /// Everything in the upload folder, newest first. Read from disk each time:
    /// the folder only ever holds what someone just dropped in.
    func uploadedFiles() -> [UploadedFile] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url -> UploadedFile? in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return UploadedFile(url: url,
                                name: url.lastPathComponent,
                                size: Int64(values?.fileSize ?? 0),
                                added: values?.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.added > $1.added }
    }

    func refreshStored() {
        storedCount = uploadedFiles().count
    }

    // MARK: Page

    private func buildPage() -> Data {
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.count ?? 0
        let html = """
        <!doctype html>
        <html lang="en">
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Aria — \(L("Wi-Fi transfer"))</title>
        <style>
          :root { color-scheme: light dark; }
          * { box-sizing: border-box; }
          body {
            margin: 0; min-height: 100vh; display: flex; flex-direction: column;
            align-items: center; justify-content: center; gap: 18px; padding: 32px 20px;
            font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            background: Canvas; color: CanvasText;
          }
          h1 { font-size: 22px; margin: 0; font-weight: 600; letter-spacing: -0.01em; }
          .sub { margin: 0; opacity: 0.6; font-size: 13px; }
          .drop {
            width: min(620px, 100%); padding: 40px 24px; border-radius: 18px;
            border: 1.5px dashed color-mix(in srgb, CanvasText 25%, transparent);
            text-align: center; cursor: pointer; transition: background 120ms, border-color 120ms;
          }
          .drop.over { border-color: #6f63d8; background: color-mix(in srgb, #6f63d8 10%, transparent); }
          .drop input { display: none; }
          .pick { color: #6f63d8; font-weight: 600; text-decoration: underline; }
          ul { width: min(620px, 100%); margin: 0; padding: 0; list-style: none; }
          li { padding: 9px 2px; border-bottom: 1px solid color-mix(in srgb, CanvasText 10%, transparent);
               display: flex; justify-content: space-between; gap: 12px; font-size: 13px; }
          li span:last-child { opacity: 0.65; white-space: nowrap; }
          .ok { color: #1a8a4a; } .bad { color: #c0392b; }
          .bar { height: 3px; border-radius: 2px; background: color-mix(in srgb, CanvasText 12%, transparent);
                 overflow: hidden; margin-top: 6px; }
          .bar i { display: block; height: 100%; width: 0; background: #6f63d8; transition: width 120ms; }
          footer { font-size: 12px; opacity: 0.5; margin-top: 6px; text-align: center; }
        </style>
        <h1>\(L("Wi-Fi transfer"))</h1>
        <p class="sub">\(L("Drop music files here — they land in Aria on this iPhone."))</p>
        <label class="drop" id="drop">
          <input id="picker" type="file" multiple>
          <span class="pick">\(L("Choose files…"))</span> \(L("or drag them onto this page"))<br>
          <small style="opacity:.55">\(L("FLAC, ALAC, WAV, AIFF, CAF, MP3, AAC — plus .lrc lyrics with the same name"))</small>
        </label>
        <ul id="list"></ul>
        <footer>\(String(format: L("%d files in “Wi-Fi Uploads” · keep Aria open while transferring."), existing))</footer>
        <script>
        const list = document.getElementById('list');
        const drop = document.getElementById('drop');
        const picker = document.getElementById('picker');
        let queue = [], busy = false;

        ['dragenter','dragover'].forEach(e => drop.addEventListener(e, ev => {
          ev.preventDefault(); drop.classList.add('over');
        }));
        ['dragleave','drop'].forEach(e => drop.addEventListener(e, ev => {
          ev.preventDefault(); drop.classList.remove('over');
        }));
        drop.addEventListener('drop', ev => enqueue([...ev.dataTransfer.files]));
        picker.addEventListener('change', ev => enqueue([...ev.target.files]));

        function enqueue(files) {
          files.forEach(f => queue.push(f));
          pump();
        }

        function row(name) {
          const li = document.createElement('li');
          const left = document.createElement('span'); left.textContent = name;
          const right = document.createElement('span'); right.textContent = '\(L("Waiting…"))';
          const bar = document.createElement('div'); bar.className = 'bar';
          const fill = document.createElement('i'); bar.appendChild(fill);
          const wrap = document.createElement('div'); wrap.style.flex = '1';
          wrap.appendChild(left); wrap.appendChild(bar);
          li.appendChild(wrap); li.appendChild(right);
          list.prepend(li);
          return { right, fill };
        }

        function pump() {
          if (busy) return;
          const file = queue.shift();
          if (!file) return;
          busy = true;
          const ui = row(file.name);
          const body = new FormData(); body.append('file', file, file.name);
          const xhr = new XMLHttpRequest();
          xhr.open('POST', 'upload');
          xhr.upload.onprogress = e => {
            if (e.lengthComputable) {
              ui.fill.style.width = Math.round(e.loaded / e.total * 100) + '%';
              ui.right.textContent = Math.round(e.loaded / e.total * 100) + '%';
            }
          };
          xhr.onload = () => {
            ui.fill.style.width = '100%';
            const done = xhr.status >= 200 && xhr.status < 300;
            ui.right.textContent = done ? '\(L("Done"))' : '\(L("Failed"))';
            ui.right.className = done ? 'ok' : 'bad';
            busy = false; pump();
          };
          xhr.onerror = () => {
            ui.right.textContent = '\(L("Failed"))';
            ui.right.className = 'bad';
            busy = false; pump();
          };
          xhr.send(body);
        }
        </script>
        </html>
        """
        return Data(html.utf8)
    }

    // MARK: Address

    /// The Wi-Fi address, so the page can be opened by IP. `en0` first; any other
    /// non-loopback IPv4 is better than nothing (personal hotspot, Ethernet).
    private static func localIPv4Address() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var fallback: String?
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP, flags & IFF_LOOPBACK == 0 else { continue }
            guard let address = pointer.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len),
                              &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if String(cString: pointer.pointee.ifa_name) == "en0" { return ip }
            if fallback == nil { fallback = ip }
        }
        return fallback
    }
}

// MARK: - One connection

/// Reads one HTTP/1.1 request, streams a `multipart/form-data` body to disk and
/// answers. Connections are closed after the response — no keep-alive, which
/// keeps the state machine honest.
private final class TransferConnection {
    private let connection: NWConnection
    private let basePath: String
    private let folder: URL
    private let page: Data
    private let notFoundPage: Data
    private let fallbackName: String
    private let queue: DispatchQueue
    private let onSaved: ([String]) -> Void
    private let onClosed: () -> Void

    private var headerBuffer = Data()
    private var request: Request?
    private var bodyRemaining = 0
    private var parser: MultipartParser?
    private var finished = false
    private var responded = false
    private var closed = false

    private static let crlfcrlf = Data("\r\n\r\n".utf8)

    struct Request {
        let method: String
        let path: String
        let headers: [String: String]
    }

    init(connection: NWConnection, basePath: String, folder: URL, page: Data,
         notFoundPage: Data, fallbackName: String,
         queue: DispatchQueue,
         onSaved: @escaping ([String]) -> Void,
         onClosed: @escaping () -> Void) {
        self.connection = connection
        self.basePath = basePath
        self.folder = folder
        self.page = page
        self.notFoundPage = notFoundPage
        self.fallbackName = fallbackName
        self.queue = queue
        self.onSaved = onSaved
        self.onClosed = onClosed
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.close() }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.consume(data) }
            if error != nil { self.close(); return }
            // Once a response is on its way the send completion closes the
            // connection; cancelling here would cut the response off.
            if self.responded { return }
            if complete && self.request == nil { self.close(); return }
            self.receive()
        }
    }

    private func consume(_ data: Data) {
        if request == nil {
            headerBuffer.append(data)
            guard let end = headerBuffer.range(of: Self.crlfcrlf) else {
                if headerBuffer.count > 16 * 1024 {
                    respond(status: 431, reason: "Request Header Fields Too Large",
                            body: Data(), type: "text/plain")
                }
                return
            }
            let head = Data(headerBuffer[..<end.lowerBound])
            let leftover = Data(headerBuffer[end.upperBound...])
            headerBuffer.removeAll()

            guard let parsed = Self.parse(head) else {
                respond(status: 400, reason: "Bad Request", body: Data(), type: "text/plain")
                return
            }
            request = parsed
            route(parsed, leftover: leftover)
            return
        }

        guard let parser else { return }
        let take = min(data.count, bodyRemaining)
        if take > 0 { parser.feed(Data(data.prefix(take))) }
        bodyRemaining -= take
        if bodyRemaining <= 0 { finishUpload() }
    }

    private func route(_ request: Request, leftover: Data) {
        let path = request.path
        if request.method == "GET", path == basePath || path == basePath + "index.html" {
            respond(status: 200, reason: "OK", body: page, type: "text/html; charset=utf-8")
            return
        }

        guard request.method == "POST", path == basePath + "upload" else {
            respond(status: 404, reason: "Not Found", body: notFoundPage,
                    type: "text/html; charset=utf-8")
            return
        }

        guard let length = request.headers["content-length"].flatMap(Int.init),
              length > 0,
              let boundary = Self.boundary(from: request.headers["content-type"]) else {
            respond(status: 400, reason: "Bad Request", body: Data(), type: "text/plain")
            return
        }

        let parser = MultipartParser(boundary: boundary, folder: folder,
                                     fallbackName: fallbackName)
        self.parser = parser
        bodyRemaining = length
        if !leftover.isEmpty {
            let take = min(leftover.count, bodyRemaining)
            if take > 0 { parser.feed(Data(leftover.prefix(take))) }
            bodyRemaining -= take
        }
        if bodyRemaining <= 0 { finishUpload() }
    }

    private func finishUpload() {
        guard !finished else { return }
        finished = true
        let names = parser?.finish() ?? []
        onSaved(names)
        let json = "{\"saved\":\(names.count)}"
        respond(status: 200, reason: "OK", body: Data(json.utf8), type: "application/json")
    }

    // MARK: Responses

    private func respond(status: Int, reason: String, body: Data, type: String) {
        guard !responded else { return }
        responded = true

        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(type)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"

        var payload = Data(head.utf8)
        payload.append(body)

        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }

    private func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClosed()
    }

    // MARK: Parsing helpers

    private static func parse(_ head: Data) -> Request? {
        guard let text = String(data: head, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }

        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        let method = String(requestLine[0]).uppercased()
        let rawPath = String(requestLine[1])
        let path = String(rawPath.split(separator: "?", maxSplits: 1).first ?? "")

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        return Request(method: method, path: path, headers: headers)
    }

    private static func boundary(from contentType: String?) -> String? {
        guard let contentType else { return nil }
        for part in contentType.split(separator: ";") {
            let piece = part.trimmingCharacters(in: .whitespaces)
            guard piece.lowercased().hasPrefix("boundary=") else { continue }
            var value = String(piece.dropFirst("boundary=".count))
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

// MARK: - multipart/form-data → files

/// Streams a multipart body into files without holding it in memory: only a
/// boundary's worth of bytes is ever buffered.
private final class MultipartParser {
    private enum State { case preamble, headers, body, done }

    private let marker: Data        // "\r\n--<boundary>"
    private let opening: Data       // "--<boundary>"
    private let folder: URL
    private let fallbackName: String
    private var state: State = .preamble
    private var buffer = Data()
    private var handle: FileHandle?
    private var currentURL: URL?
    private var saved: [String] = []

    init(boundary: String, folder: URL, fallbackName: String) {
        self.marker = Data("\r\n--\(boundary)".utf8)
        self.opening = Data("--\(boundary)".utf8)
        self.folder = folder
        self.fallbackName = fallbackName
    }

    func feed(_ chunk: Data) {
        buffer.append(chunk)
        pump()
    }

    /// Flushes whatever is left and reports the names that made it to disk.
    func finish() -> [String] {
        if state == .body, !buffer.isEmpty {
            write(buffer)
            buffer.removeAll()
        }
        closeFile()
        return saved
    }

    private func pump() {
        while true {
            switch state {
            case .preamble:
                guard let range = buffer.range(of: opening) else {
                    // Keep only what could still be the start of a boundary.
                    trim(keeping: opening.count + 2)
                    return
                }
                buffer.removeSubrange(0..<range.upperBound)
                state = .headers

            case .headers:
                guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    // Part headers are tiny; wait for the rest instead of
                    // dropping bytes that belong to the next one.
                    if buffer.count > 64 * 1024 { state = .done }
                    return
                }
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                buffer.removeSubrange(0..<end.upperBound)
                openFile(named: Self.filename(from: head))
                state = .body

            case .body:
                guard let range = buffer.range(of: marker) else {
                    // No delimiter yet: everything except a possible split
                    // marker is file content, so it has to be written — not
                    // dropped, which is what silently truncated uploads.
                    let keep = marker.count + 1
                    if buffer.count > keep {
                        let end = buffer.count - keep
                        write(Data(buffer[0..<end]))
                        buffer.removeSubrange(0..<end)
                    }
                    return
                }
                write(Data(buffer[..<range.lowerBound]))
                buffer.removeSubrange(0..<range.upperBound)

                // Followed by "--" (last part) or "\r\n" (another part).
                if buffer.count < 2 { return }
                if buffer.starts(with: Data("--".utf8)) {
                    buffer.removeSubrange(0..<2)
                    closeFile()
                    state = .done
                    return
                } else if buffer.starts(with: Data("\r\n".utf8)) {
                    buffer.removeSubrange(0..<2)
                    closeFile()
                    state = .headers
                } else {
                    state = .done
                    return
                }

            case .done:
                buffer.removeAll()
                return
            }
        }
    }

    private func trim(keeping tail: Int) {
        guard buffer.count > tail else { return }
        buffer.removeSubrange(0..<(buffer.count - tail))
    }

    // MARK: Files

    private func openFile(named rawName: String?) {
        closeFile()
        let name = Self.sanitized(rawName ?? fallbackName, fallback: fallbackName)
        let target = folder.appendingPathComponent(name)
        // Same name means the same track, so the second copy replaces the first
        // instead of piling up " 2", " 3" duplicates in the library.
        // `createFile` truncates an existing file, which is what makes the
        // overwrite safe for a shorter upload as well.
        // The folder can disappear mid-session (Files app, "offload app"), so
        // make sure it is back before a file handle is asked for.
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: target.path, contents: nil)
        handle = try? FileHandle(forWritingTo: target)
        currentURL = target
    }

    private func write(_ data: Data) {
        guard !data.isEmpty, let handle else { return }
        try? handle.write(contentsOf: data)
    }

    private func closeFile() {
        guard let handle else { return }
        try? handle.close()
        self.handle = nil
        if let currentURL {
            saved.append(currentURL.lastPathComponent)
            self.currentURL = nil
        }
    }

    private static func filename(from head: String) -> String? {
        for line in head.components(separatedBy: "\r\n") {
            guard line.lowercased().hasPrefix("content-disposition") else { continue }
            // filename*=UTF-8''… wins over filename="…"
            if let star = value(of: "filename*", in: line) {
                let stripped = star.split(separator: "'", maxSplits: 2).last.map(String.init) ?? star
                return stripped.removingPercentEncoding ?? stripped
            }
            if let plain = value(of: "filename", in: line) { return plain }
        }
        return nil
    }

    private static func value(of key: String, in line: String) -> String? {
        guard let range = line.range(of: key + "=") else { return nil }
        var rest = line[range.upperBound...]
        if rest.hasPrefix("\"") {
            rest = rest.dropFirst()
            guard let close = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[..<close])
        }
        return String(rest.split(separator: ";").first ?? rest)
    }

    /// Keeps the file inside the upload folder and printable in Files.
    private static func sanitized(_ raw: String, fallback: String) -> String {
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|")
        // "." and ".." segments are dropped rather than kept: a browser should
        // never be able to steer a name above the upload folder.
        let parts = raw.components(separatedBy: banned)
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        var name = parts.joined(separator: "-").trimmingCharacters(in: .whitespaces)
        if name == "." || name == ".." || name.isEmpty { name = fallback }
        if name.count > 120 { name = String(name.prefix(120)) }
        return name
    }
}
#endif
