import Foundation

@MainActor
enum PreviewStylesheet {
    /// The preference values the stylesheet reads. Two `AppPreferences`
    /// instances with equal signatures produce byte-identical CSS, so the
    /// signature doubles as the memoization key here and as part of the
    /// rendered-page cache key in the preview.
    struct StyleSignature: Hashable, Sendable {
        let fontFamily: String
        let fontSize: Int
        let pageWidth: Int
        let codeFontFamily: String

        // Nested types do not inherit the enclosing enum's actor isolation,
        // and `AppPreferences` is main-actor bound.
        @MainActor
        init(preferences: AppPreferences) {
            fontFamily = preferences.previewFontChoice.cssFontFamily
            fontSize = Int(preferences.previewFontSize.rounded())
            pageWidth = Int(preferences.previewPageWidth.rounded())
            codeFontFamily = preferences.previewCodeFontChoice.cssFontFamily
        }
    }

    // Single-entry memo of the generated stylesheet. The preferences change
    // rarely while the page is re-rendered on every keystroke, so one slot is
    // enough. `page(...)` itself is not memoized here (the preview keeps a
    // page cache of its own); instead it is a pure function of its inputs, so
    // an unchanged body always yields a byte-identical page and the web view
    // is not reloaded.
    private static var cachedStylesheet: (signature: StyleSignature, css: String)?

    // Process-lifetime secret mixed into every CSP nonce. Together with
    // `Hasher`'s per-process random seed it keeps nonces unpredictable to
    // anyone authoring note content, while letting the same body map to the
    // same nonce.
    private static let nonceSalt = UUID().uuidString

    /// Derives the CSP nonce from the page body instead of minting a random
    /// one per call. A random nonce made every render differ byte for byte,
    /// which made `HTMLPreviewWebView` reload (and flicker) an unchanged page.
    private static func makeNonce(forBody body: String) -> String {
        var first = Hasher()
        first.combine(nonceSalt)
        first.combine(body)
        var second = Hasher()
        second.combine(body)
        second.combine(nonceSalt)
        second.combine(1 as UInt8)
        let high = String(UInt64(bitPattern: Int64(first.finalize())), radix: 16)
        let low = String(UInt64(bitPattern: Int64(second.finalize())), radix: 16)
        return "n" + high + low
    }

    static func page(body: String, preferences: AppPreferences, compact: Bool = false) -> String {
        let stylesheet = css(using: preferences)
        let needsMath = body.contains("class=\"math-inline\"") || body.contains("class=\"math-display\"")
        let mathAssets = needsMath ? mathAssetsHTML : ""
        // The nonce authorizes only our own inline bootstrap script. Raw user
        // HTML is escaped before rendering, so it is never injectable.
        let nonce = makeNonce(forBody: body)

        // Defense-in-depth CSP. Even though cmark now renders in safe mode (no
        // raw user HTML, no unsafe link schemes), this hard-stops the
        // exfiltration path: `connect-src 'none'` blocks fetch/XHR/beacons,
        // `script-src` permits only the bundled KaTeX asset and the nonced
        // bootstrap, and frames/objects/forms are denied outright. `img-src`
        // still allows https/data so images and YouTube cards keep working.
        let csp = [
            "default-src 'none'",
            "img-src 'self' data: file: katex-asset: https:",
            "style-src 'unsafe-inline' katex-asset:",
            "font-src katex-asset: data:",
            "script-src 'nonce-\(nonce)' katex-asset:",
            "connect-src 'none'",
            "base-uri 'none'",
            "form-action 'none'",
            "frame-src 'none'",
            "object-src 'none'"
        ].joined(separator: "; ")

        let page = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <meta name="color-scheme" content="light dark">
        <style>\(stylesheet)\(compact ? "html,body{padding:0;margin:0;max-width:none;overflow:hidden;background:transparent}body{display:flow-root}" : "")</style>
        \(mathAssets)
        </head>
        <body>\(body)\(needsMath ? mathBootstrapScript(nonce: nonce) : "")</body>
        </html>
        """
        return page
    }

    // KaTeX 0.16.11 served from the app bundle via a custom URL scheme
    // registered on the preview's WKWebView (see KaTeXBundleSchemeHandler).
    // Rendering works fully offline.
    private static let mathAssetsHTML = """
    <link rel="stylesheet" href="katex-asset:///katex.min.css">
    <script defer src="katex-asset:///katex.min.js"></script>
    """

    private static func mathBootstrapScript(nonce: String) -> String {
        """
    <script nonce="\(nonce)">
    document.addEventListener('DOMContentLoaded', function() {
        if (typeof katex === 'undefined') { return; }
        function renderAll(selector, displayMode) {
            document.querySelectorAll(selector).forEach(function(el) {
                try {
                    katex.render(el.textContent, el, { displayMode: displayMode, throwOnError: false });
                    el.classList.add('katex-rendered');
                } catch (e) {
                    console.error('KaTeX render failed:', e);
                }
            });
        }
        renderAll('.math-inline', false);
        renderAll('.math-display', true);
    });
    </script>
    """
    }

    static func css(using preferences: AppPreferences) -> String {
        css(for: StyleSignature(preferences: preferences))
    }

    static func css(for signature: StyleSignature) -> String {
        if let cachedStylesheet, cachedStylesheet.signature == signature {
            return cachedStylesheet.css
        }

        let stylesheet = buildCSS(for: signature)
        cachedStylesheet = (signature, stylesheet)
        return stylesheet
    }

    private static func buildCSS(for signature: StyleSignature) -> String {
        let previewFontFamily = signature.fontFamily
        let previewFontSize = signature.fontSize
        let previewPageWidth = signature.pageWidth
        let previewCodeFontFamily = signature.codeFontFamily

        return """
    * { margin: 0; padding: 0; box-sizing: border-box; }

    :root { color-scheme: light dark; }

    html {
        background: #ffffff;
    }

    body {
        font-family: \(previewFontFamily);
        font-size: \(previewFontSize)px;
        line-height: 1.75;
        color: #1d1d1f;
        background: transparent;
        max-width: \(previewPageWidth)px;
        margin: 0 auto;
        padding: 48px 72px 120px;
        -webkit-font-smoothing: antialiased;
    }

    @media (prefers-color-scheme: dark) {
        html { background: #1e1e1e; }
        body { color: #f5f5f7; }
    }

    @media (max-width: 980px) {
        body {
            padding-left: 40px;
            padding-right: 40px;
        }
    }

    h1, h2, h3, h4, h5, h6 {
        font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Helvetica Neue', sans-serif;
        font-weight: 700;
        line-height: 1.3;
        margin-top: 1.6em;
        margin-bottom: 0.6em;
        letter-spacing: -0.01em;
    }

    h1:first-child, h2:first-child, h3:first-child { margin-top: 0; }

    h1 {
        font-size: 2.2em;
        font-weight: 800;
        letter-spacing: -0.025em;
        border-bottom: 1px solid #d2d2d7;
        padding-bottom: 0.35em;
    }

    h2 {
        font-size: 1.6em;
        border-bottom: 1px solid rgba(210,210,215,0.4);
        padding-bottom: 0.25em;
    }

    h3 { font-size: 1.3em; }
    h4 { font-size: 1.1em; }
    h5, h6 { font-size: 1em; color: #86868b; }

    @media (prefers-color-scheme: dark) {
        h1 { border-bottom-color: #424245; }
        h2 { border-bottom-color: rgba(66,66,69,0.5); }
        h5, h6 { color: #a1a1a6; }
    }

    p { margin: 0.85em 0; }

    a {
        color: #0071e3;
        text-decoration: none;
        border-bottom: 1px solid rgba(0,113,227,0.3);
        transition: border-color 0.15s;
    }

    a:hover { border-bottom-color: #0071e3; }

    @media (prefers-color-scheme: dark) {
        a { color: #2997ff; border-bottom-color: rgba(41,151,255,0.3); }
        a:hover { border-bottom-color: #2997ff; }
    }

    strong { font-weight: 600; }
    em { font-style: italic; }
    del { text-decoration: line-through; opacity: 0.6; }

    code {
        font-family: \(previewCodeFontFamily);
        font-size: 0.88em;
        background: rgba(0,0,0,0.05);
        padding: 0.15em 0.45em;
        border-radius: 5px;
    }

    @media (prefers-color-scheme: dark) {
        code { background: rgba(255,255,255,0.08); }
    }

    pre {
        background: #f5f5f7;
        border-radius: 10px;
        padding: 18px 22px;
        overflow-x: auto;
        margin: 1.2em 0;
        border: 1px solid rgba(0,0,0,0.06);
    }

    pre code {
        background: none;
        padding: 0;
        font-size: 0.85em;
        line-height: 1.6;
        border-radius: 0;
    }

    @media (prefers-color-scheme: dark) {
        pre { background: #1c1c1e; border-color: rgba(255,255,255,0.06); }
    }

    blockquote {
        border-left: 3px solid #0071e3;
        margin: 1.2em 0;
        padding: 0.6em 1.2em;
        color: #6e6e73;
        background: rgba(0,113,227,0.04);
        border-radius: 0 8px 8px 0;
    }

    @media (prefers-color-scheme: dark) {
        blockquote {
            color: #a1a1a6;
            border-left-color: #2997ff;
            background: rgba(41,151,255,0.06);
        }
    }

    ul, ol { padding-left: 1.6em; margin: 0.85em 0; }
    li { margin: 0.35em 0; }
    li > ul, li > ol { margin: 0.2em 0; }

    li::marker { color: #86868b; }

    @media (prefers-color-scheme: dark) {
        li::marker { color: #636366; }
    }

    hr {
        border: none;
        height: 1px;
        background: linear-gradient(to right, transparent, #d2d2d7, transparent);
        margin: 2.5em 0;
    }

    @media (prefers-color-scheme: dark) {
        hr { background: linear-gradient(to right, transparent, #424245, transparent); }
    }

    table {
        border-collapse: collapse;
        width: 100%;
        margin: 1.2em 0;
        font-size: 0.95em;
    }

    th, td {
        border: 1px solid #d2d2d7;
        padding: 10px 14px;
        text-align: left;
    }

    th {
        background: rgba(0,0,0,0.03);
        font-weight: 600;
        font-size: 0.9em;
        text-transform: uppercase;
        letter-spacing: 0.03em;
    }

    @media (prefers-color-scheme: dark) {
        th, td { border-color: #424245; }
        th { background: rgba(255,255,255,0.04); }
    }

    img {
        max-width: 100%;
        border-radius: 10px;
        margin: 1em 0;
    }

    .youtube-card {
        display: block;
        border: none;
        border-radius: 12px;
        overflow: hidden;
        margin: 0.8em 0;
        background: rgba(0,0,0,0.04);
        text-decoration: none;
        transition: none;
    }

    .youtube-card:hover {
        border-bottom: none;
    }

    .youtube-thumb-wrap {
        position: relative;
        width: 100%;
        aspect-ratio: 16/9;
        overflow: hidden;
        background: #000;
    }

    .youtube-thumb {
        width: 100%;
        height: 100%;
        object-fit: cover;
        border-radius: 0;
        margin: 0;
    }

    .youtube-play {
        position: absolute;
        top: 50%;
        left: 50%;
        transform: translate(-50%, -50%);
        opacity: 0.85;
        transition: opacity 0.15s, transform 0.15s;
    }

    .youtube-card:hover .youtube-play {
        opacity: 1;
    }

    .youtube-title {
        display: block;
        padding: 10px 14px;
        font-size: 0.9em;
        font-weight: 500;
        line-height: 1.4;
        color: #1d1d1f;
    }

    @media (prefers-color-scheme: dark) {
        .youtube-card { background: rgba(255,255,255,0.06); }
        .youtube-card:hover { border-bottom: none; }
        .youtube-title { color: #f5f5f7; }
    }

    .mermaid-diagram {
        text-align: center;
        margin: 1.2em 0;
    }

    .mermaid-diagram svg {
        max-width: 100%;
        height: auto;
    }

    .math-display {
        display: block;
        text-align: center;
        margin: 1.2em 0;
        overflow-x: auto;
        overflow-y: hidden;
    }

    .math-inline {
        display: inline;
    }

    /* Fallback rendering before KaTeX loads (or if it fails to load) so
       LaTeX source is at least legible. */
    .math-display:not(.katex-rendered),
    .math-inline:not(.katex-rendered) {
        font-family: \(previewCodeFontFamily);
        font-size: 0.95em;
    }
    """
    }
}
