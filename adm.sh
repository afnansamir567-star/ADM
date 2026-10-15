#!/bin/bash

# ================================================================
#  ADM — A. Professor's Download Manager  v2.1.0
#  Author : Afnan Samir
# ================================================================

VERSION="v2.1.0"
APP_NAME="ADM"
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
TMUX_SESSION="adm"
HEADER_LINES=17

# -- Colors ------------------------------------------------------
R='\033[0;31m'
G='\033[0;32m'
Y='\033[1;33m'
C='\033[0;36m'
W='\033[1;37m'
M='\033[0;35m'
DIM='\033[2m'
BOLD='\033[1m'
N='\033[0m'

# ================================================================
# OS DETECT
# ================================================================
detect_os() {
    if [ -d "/data/data/com.termux" ]; then
        OS_TYPE="android"
        BASE_SAVE="/sdcard/Download/ADM"
        TMP_DIR="/data/data/com.termux/files/usr/tmp"
    else
        OS_TYPE="linux"
        BASE_SAVE="$HOME/Downloads/ADM"
        TMP_DIR="/tmp"
    fi
    mkdir -p "$BASE_SAVE" "$TMP_DIR"
}
detect_os

# ================================================================
# SELF INSTALL — makes "adm" runnable from anywhere, any directory
# ================================================================
_adm_bin_dir() {
    if [ "$OS_TYPE" = "android" ]; then
        echo "$PREFIX/bin"
    else
        mkdir -p "$HOME/.local/bin" 2>/dev/null
        echo "$HOME/.local/bin"
    fi
}

auto_self_install() {
    local BIN_DIR TARGET
    BIN_DIR="$(_adm_bin_dir)"
    TARGET="$BIN_DIR/adm"

    # Already running from the installed location — nothing to do
    [ "$SCRIPT_PATH" = "$TARGET" ] && return

    # Already installed and identical — nothing to do
    if [ -f "$TARGET" ] && cmp -s "$SCRIPT_PATH" "$TARGET" 2>/dev/null; then
        return
    fi

    cp -f "$SCRIPT_PATH" "$TARGET" 2>/dev/null && chmod +x "$TARGET" 2>/dev/null

    # Linux: make sure $BIN_DIR is on PATH for future shells
    if [ "$OS_TYPE" = "linux" ]; then
        case ":$PATH:" in
            *":$BIN_DIR:"*) ;;
            *)
                for RC in "$HOME/.bashrc" "$HOME/.zshrc"; do
                    if [ -f "$RC" ] && ! grep -q "$BIN_DIR" "$RC" 2>/dev/null; then
                        echo "export PATH=\"$BIN_DIR:\$PATH\"" >> "$RC"
                    fi
                done
                export PATH="$BIN_DIR:$PATH"
                ;;
        esac
    fi
}

# ================================================================
# SELF UPDATE — pulls a newer adm.sh from a URL you set in cfg
# ================================================================
self_update() {
    local URL; URL=$(get_setting update_url)
    if [ -z "$URL" ]; then
        echo -e "${Y}  No update URL set.${N}"
        echo -e "${DIM}  Set one first: cfg > Update URL  (a raw .sh link, e.g. GitHub raw URL)${N}"
        log_msg "WARN" "Self-update attempted with no update_url set"
        return 1
    fi

    echo -e "${C}  Downloading latest version from:${N} ${DIM}${URL}${N}"
    local TMP_NEW="${TMP_DIR}/adm_update_$$.sh"
    if curl -fsSL "$URL" -o "$TMP_NEW" 2>/dev/null || wget -q "$URL" -O "$TMP_NEW" 2>/dev/null; then
        if [ -s "$TMP_NEW" ] && bash -n "$TMP_NEW" 2>/dev/null; then
            cp -f "$TMP_NEW" "$SCRIPT_PATH" 2>/dev/null
            chmod +x "$SCRIPT_PATH" 2>/dev/null
            # Keep the installed "adm" binary in sync too, if different from SCRIPT_PATH
            local _BD; _BD="$(_adm_bin_dir)"
            [ "$SCRIPT_PATH" != "${_BD}/adm" ] && cp -f "$SCRIPT_PATH" "${_BD}/adm" 2>/dev/null && chmod +x "${_BD}/adm" 2>/dev/null
            rm -f "$TMP_NEW" 2>/dev/null
            echo -e "${G}  [OK] Updated successfully. Run 'adm' again to use the new version.${N}"
            log_msg "INFO" "Self-update succeeded from ${URL}"
        else
            rm -f "$TMP_NEW" 2>/dev/null
            echo -e "${R}  Downloaded file looks invalid — update aborted, nothing was changed.${N}"
            log_msg "ERROR" "Self-update download invalid from ${URL}"
            return 1
        fi
    else
        echo -e "${R}  Download failed. Check the URL and your network.${N}"
        log_msg "ERROR" "Self-update download failed from ${URL}"
        return 1
    fi
}

# ================================================================
# SELF UNINSTALL — removes the adm binary and all its data
# ================================================================
self_uninstall() {
    clear 2>/dev/null
    local _BD; _BD="$(_adm_bin_dir)"
    echo -e "${Y}  This will permanently remove:${N}"
    echo -e "  ${DIM}- ${_BD}/adm${N}"
    echo -e "  ${DIM}- ${DATA_DIR} (settings, history, cookies, log)${N}"
    echo ""
    echo -ne "  ${R}Type YES to confirm: ${N}"
    read -r _CONFIRM
    if [ "$_CONFIRM" != "YES" ]; then
        echo -e "${DIM}  Cancelled. Nothing was removed.${N}"
        return 1
    fi
    rm -f "${_BD}/adm" 2>/dev/null
    rm -rf "$DATA_DIR" 2>/dev/null
    [ "$OS_TYPE" = "linux" ] && tmux kill-session -t "$TMUX_SESSION" 2>/dev/null
    echo -e "${G}  ADM removed. Goodbye!${N}"
    exit 0
}

# Only self-install on the real user invocation, not the internal
# "--header-loop" / "--main" relaunches used inside tmux panes.
[ -z "${1:-}" ] && auto_self_install

# ================================================================
# DATA FILES
# ================================================================
DATA_DIR="$BASE_SAVE/.data"
SETUP_FLAG="$DATA_DIR/setup_done"
STATS_FILE="$DATA_DIR/stats.json"
COOKIE_FILE="$DATA_DIR/cookies.txt"
SETTINGS_FILE="$DATA_DIR/settings.json"
PLAYER_SETTINGS="$DATA_DIR/player.json"
HISTORY_FILE="$DATA_DIR/history.json"
LOG_FILE="$DATA_DIR/adm.log"
mkdir -p "$DATA_DIR"

FETCHER="$DATA_DIR/adm_fetch.py"
_ADM_PC_DIR="${TMP_DIR}/adm_pc_$$"

# The direct-file engine (any file type) is embedded below and written
# next to the settings, so adm.sh stays a single self-contained file.
_write_fetcher() {
    cat > "${FETCHER}.new" << 'PYEOF'
# ADM-FETCH-VERSION: 1
# ADM direct-file engine — stdlib only. Downloads ANY file type (not just video).
#
#   adm_fetch.py probe  URL [opts]            -> key=value lines (kind/name/size/...)
#   adm_fetch.py get    URL --outdir DIR [..] -> yt-dlp style progress lines, final path
#   adm_fetch.py scan   URL [opts]            -> tab separated downloadable links of a page
#   adm_fetch.py fixext PATH_OR_DIR           -> repair wrong/missing extensions
import sys, os, re, json, time, ssl, socket, threading, struct, zipfile, argparse, signal
import ipaddress, mimetypes, http.client, http.cookiejar, urllib.request, urllib.error
from collections import deque
from html.parser import HTMLParser
from urllib.parse import urlsplit, urlunsplit, unquote, quote, parse_qs, urljoin, urlencode

UA = ("Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36")
MIN_SEGMENT_SIZE = 4 * 1024 * 1024          # below this: single connection
HTML_TYPES = ("text/html", "application/xhtml+xml")

# ---------------------------------------------------------------- categories
CATS = {
    "Video":     "mp4 mkv webm avi mov wmv flv mpg mpeg 3gp m4v ogv ts m2ts vob",
    "Audio":     "mp3 m4a aac flac wav ogg opus wma aiff amr mid midi",
    "Images":    "jpg jpeg png gif webp bmp svg ico tif tiff heic heif avif raw psd",
    "Documents": "pdf doc docx xls xlsx ppt pptx odt ods odp txt rtf csv epub mobi azw3 "
                 "djvu md tex pages numbers key json xml yaml yml log sql",
    "Archives":  "zip rar 7z tar gz tgz bz2 xz zst lz cab iso img dmg z",
    "Apps":      "apk xapk apks apkm aab exe msi deb rpm pkg appimage jar ipa bat sh run",
    "Fonts":     "ttf otf woff woff2 eot",
}
EXT2CAT = {e: c for c, s in CATS.items() for e in s.split()}
SCRIPTY = {"php", "asp", "aspx", "jsp", "cgi", "do", "action", "ashx", "axd", "html", "htm"}
BAD_EXTS = {"", "unknown_video", "unknown_audio", "unknown", "download", "tmp",
            "octet-stream"} | SCRIPTY          # extensions that say nothing about the content
TEXTY = {".txt", ".json", ".xml", ".svg", ".sh", ".html"}
WEB_EXTS = {"html", "htm", "xhtml", "php", "asp", "aspx", "jsp", "cgi", "js", "mjs",
            "css", "map", "woff-map"}
MIME_FIX = {
    "application/vnd.android.package-archive": ".apk",
    "application/zip": ".zip", "application/x-zip-compressed": ".zip",
    "application/x-rar-compressed": ".rar", "application/vnd.rar": ".rar",
    "application/x-7z-compressed": ".7z", "application/gzip": ".gz",
    "application/x-gzip": ".gz", "application/x-tar": ".tar",
    "application/x-bzip2": ".bz2", "application/x-xz": ".xz",
    "application/pdf": ".pdf", "application/epub+zip": ".epub",
    "application/msword": ".doc",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document": ".docx",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": ".xlsx",
    "application/vnd.openxmlformats-officedocument.presentationml.presentation": ".pptx",
    "application/vnd.ms-excel": ".xls", "application/vnd.ms-powerpoint": ".ppt",
    "application/x-msdownload": ".exe", "application/vnd.microsoft.portable-executable": ".exe",
    "application/x-debian-package": ".deb", "application/java-archive": ".jar",
    "application/json": ".json", "application/xml": ".xml", "text/plain": ".txt",
    "text/csv": ".csv", "audio/mpeg": ".mp3", "audio/mp4": ".m4a", "audio/x-m4a": ".m4a",
    "audio/ogg": ".ogg", "audio/wav": ".wav", "audio/x-wav": ".wav", "audio/flac": ".flac",
    "video/mp4": ".mp4", "video/webm": ".webm", "video/x-matroska": ".mkv",
    "video/quicktime": ".mov", "video/x-msvideo": ".avi", "video/3gpp": ".3gp",
    "image/jpeg": ".jpg", "image/png": ".png", "image/gif": ".gif", "image/webp": ".webp",
    "image/svg+xml": ".svg", "image/avif": ".avif", "image/heic": ".heic",
    "font/ttf": ".ttf", "font/otf": ".otf", "font/woff": ".woff", "font/woff2": ".woff2",
}


def category_of(name):
    ext = os.path.splitext(name)[1].lower().lstrip(".")
    return EXT2CAT.get(ext, "Other")


# -------------------------------------------------------------------- output
def out(msg=""):
    sys.stdout.write(msg + "\n")
    sys.stdout.flush()


def fmt_size(n):
    if n is None:
        return "?"
    n = float(n)
    for u in ("B", "KiB", "MiB", "GiB", "TiB"):
        if n < 1024 or u == "TiB":
            return ("%.0f%s" % (n, u)) if u == "B" else ("%.2f%s" % (n, u))
        n /= 1024


def fmt_eta(s):
    if s is None or s < 0 or s > 99 * 3600:
        return "--:--"
    s = int(s)
    return "%02d:%02d" % (s // 60, s % 60)


class FetchError(Exception):
    def __init__(self, msg, code=1):
        Exception.__init__(self, msg)
        self.code = code


class SegFail(Exception):
    pass


# ------------------------------------------------------------ network layer
def norm_url(url):
    """Make a URL ASCII-safe (IRIs, spaces, Bengali file names ...)."""
    p = urlsplit(url.strip())
    path = quote(p.path, safe="/%:@!$&'()*+,;=~-._")
    query = quote(p.query, safe="=&%:@!$'()*+,;/?~-._")
    host = p.netloc
    try:
        host.encode("ascii")
    except UnicodeEncodeError:
        user = ""
        h = host
        if "@" in h:
            user, h = h.rsplit("@", 1)
            user += "@"
        port = ""
        if ":" in h and not h.endswith("]"):
            h, port = h.rsplit(":", 1)
            port = ":" + port
        host = user + h.encode("idna").decode("ascii") + port
    return urlunsplit((p.scheme, host, path, query, ""))


def _recvn(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise OSError("proxy closed the connection")
        buf += chunk
    return buf


def socks5_connect(proxy, host, port, timeout):
    """Minimal SOCKS5 client. Always sends the hostname to the proxy (no local DNS leak)."""
    s = socket.create_connection((proxy.hostname, proxy.port or 1080), timeout)
    try:
        user = unquote(proxy.username) if proxy.username else None
        pwd = unquote(proxy.password or "") if proxy.username else None
        s.sendall(b"\x05\x02\x00\x02" if user else b"\x05\x01\x00")
        r = _recvn(s, 2)
        if r[0] != 5 or r[1] == 0xFF:
            raise OSError("SOCKS5 proxy refused the handshake")
        if r[1] == 2:
            if not user:
                raise OSError("SOCKS5 proxy needs a username/password")
            u, p = user.encode(), pwd.encode()
            s.sendall(b"\x01" + bytes([len(u)]) + u + bytes([len(p)]) + p)
            if _recvn(s, 2)[1] != 0:
                raise OSError("SOCKS5 authentication failed")
        try:
            ip = ipaddress.ip_address(host)
            addr = (b"\x01" if ip.version == 4 else b"\x04") + ip.packed
        except ValueError:
            hb = host.encode("idna")
            addr = b"\x03" + bytes([len(hb)]) + hb
        s.sendall(b"\x05\x01\x00" + addr + struct.pack(">H", port))
        resp = _recvn(s, 4)
        if resp[1] != 0:
            raise OSError("SOCKS5 connect failed (code %d)" % resp[1])
        atyp = resp[3]
        if atyp == 1:
            _recvn(s, 4)
        elif atyp == 4:
            _recvn(s, 16)
        else:
            _recvn(s, _recvn(s, 1)[0])
        _recvn(s, 2)
        s.settimeout(timeout)
        return s
    except Exception:
        s.close()
        raise


class Cfg(object):
    pass


def make_ssl_context(insecure=False):
    ctx = ssl.create_default_context()
    if insecure:
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        return ctx
    if ctx.cert_store_stats().get("x509_ca", 0) == 0:     # nothing loaded: try known places
        cands = []
        try:
            import certifi
            cands.append(certifi.where())
        except Exception:
            pass
        cands += ["/data/data/com.termux/files/usr/etc/tls/cert.pem",
                  "/etc/ssl/certs/ca-certificates.crt", "/etc/ssl/cert.pem",
                  "/etc/pki/tls/certs/ca-bundle.crt"]
        for f in cands:
            if os.path.isfile(f):
                try:
                    ctx.load_verify_locations(f)
                    break
                except (ssl.SSLError, OSError):
                    continue
    return ctx


def build_opener(cfg):
    handlers = []
    ctx = make_ssl_context(cfg.insecure)
    proxy = urlsplit(cfg.proxy) if cfg.proxy else None
    if proxy and proxy.scheme in ("socks5", "socks5h"):
        class HC(http.client.HTTPConnection):
            def connect(self):
                self.sock = socks5_connect(proxy, self.host, self.port, self.timeout)

        class HSC(http.client.HTTPSConnection):
            def connect(self):
                raw = socks5_connect(proxy, self.host, self.port, self.timeout)
                self.sock = self._context.wrap_socket(raw, server_hostname=self.host)

        class H1(urllib.request.HTTPHandler):
            def http_open(self, req):
                return self.do_open(HC, req)

        class H2(urllib.request.HTTPSHandler):
            def https_open(self, req):
                return self.do_open(HSC, req, context=ctx)

        handlers += [urllib.request.ProxyHandler({}), H1(), H2()]
    elif proxy and proxy.scheme in ("http", "https"):
        handlers += [urllib.request.ProxyHandler({"http": cfg.proxy, "https": cfg.proxy}),
                     urllib.request.HTTPSHandler(context=ctx)]
    elif proxy:
        # fail closed: never silently bypass a proxy the user asked for
        raise FetchError("unsupported proxy type '%s' (use http:// or socks5://)" % proxy.scheme, 5)
    else:
        handlers.append(urllib.request.HTTPSHandler(context=ctx))
    if cfg.jar is not None:
        handlers.append(urllib.request.HTTPCookieProcessor(cfg.jar))
    return urllib.request.build_opener(*handlers)


def make_request(url, cfg, method="GET", extra=None):
    h = {"User-Agent": cfg.ua, "Accept": "*/*", "Accept-Encoding": "identity"}
    if cfg.referer:
        h["Referer"] = cfg.referer
    for line in cfg.headers:
        if ":" in line:
            k, v = line.split(":", 1)
            h[k.strip()] = v.strip()
    if extra:
        h.update(extra)
    return urllib.request.Request(norm_url(url), headers=h, method=method)


def http_error_text(e):
    return "HTTP %d %s" % (e.code, getattr(e, "reason", "") or "")


def open_url(opener, url, cfg, method="GET", extra=None):
    return opener.open(make_request(url, cfg, method, extra), timeout=cfg.timeout)


# ------------------------------------------------------------ URL resolving
def resolve_url(url):
    """Rewrite share/preview links into direct-download links."""
    p = urlsplit(url)
    host = (p.hostname or "").lower()
    if host.endswith("dropbox.com"):
        q = parse_qs(p.query, keep_blank_values=True)
        q["dl"] = ["1"]
        q.pop("raw", None)
        return urlunsplit((p.scheme, p.netloc, p.path, urlencode(q, doseq=True), ""))
    if host == "github.com":
        m = re.match(r"^/([^/]+)/([^/]+)/blob/(.+)$", p.path)
        if m:
            return "https://github.com/%s/%s/raw/%s" % m.groups()
    if host in ("drive.google.com", "docs.google.com", "drive.usercontent.google.com"):
        m = re.search(r"/file/d/([\w-]+)", p.path) or \
            re.search(r"[?&]id=([\w-]+)", "?" + p.query)
        if m and "/document/" not in p.path and "/spreadsheets/" not in p.path \
                and "/presentation/" not in p.path:
            return ("https://drive.usercontent.google.com/download?id=%s"
                    "&export=download&confirm=t" % m.group(1))
    return url


def _read_html(resp, limit=3 * 1024 * 1024):
    data = resp.read(limit)
    cs = resp.headers.get_content_charset() or "utf-8"
    return data.decode(cs, "replace")


def special_page_resolve(opener, url, cfg):
    """MediaFire file pages and Google-Drive virus-scan pages -> real file URL."""
    host = (urlsplit(url).hostname or "").lower()
    if host.endswith("mediafire.com") and "/file" in urlsplit(url).path:
        resp = open_url(opener, url, cfg)
        html = _read_html(resp)
        m = re.search(r'href="(https?://download[^"]+mediafire\.com/[^"]+)"', html) or \
            re.search(r'"(https?://download\d*\.mediafire\.com/[^"]+)"', html)
        if m:
            return m.group(1).replace("&amp;", "&")
    return None


def drive_confirm_url(html, base):
    """Parse Google Drive's 'can't scan for viruses' page into the real download URL."""
    if "download-form" not in html and "uc-download-link" not in html:
        return None
    m = re.search(r'<form[^>]+id="download-form"[^>]+action="([^"]+)"', html) or \
        re.search(r'<form[^>]+action="([^"]+)"[^>]+id="download-form"', html)
    if not m:
        m2 = re.search(r'href="(/uc\?export=download[^"]+)"', html)
        return urljoin(base, m2.group(1).replace("&amp;", "&")) if m2 else None
    action = urljoin(base, m.group(1).replace("&amp;", "&"))
    params = dict(re.findall(r'<input[^>]+type="hidden"[^>]+name="([^"]+)"[^>]+value="([^"]*)"', html))
    for k, v in re.findall(r'<input[^>]+name="([^"]+)"[^>]+type="hidden"[^>]+value="([^"]*)"', html):
        params.setdefault(k, v)
    sep = "&" if "?" in action else "?"
    return action + sep + urlencode(params)


# ----------------------------------------------------------------- file names
def sanitize_name(name, max_bytes=200):
    name = unquote(name or "")
    name = name.replace("\\", "/").split("/")[-1]
    name = re.sub(r"[\x00-\x1f\x7f<>:\"|?*]", "_", name).strip().strip(".")
    name = re.sub(r"\s+", " ", name)
    if not name:
        return ""
    base, ext = os.path.splitext(name)
    ext = ext[:16]
    limit = max_bytes - len(ext.encode("utf-8"))
    while len(base.encode("utf-8")) > limit and base:
        base = base[:-1]
    return (base or "file") + ext


def name_from_disposition(cd):
    if not cd:
        return ""
    m = re.search(r"filename\*\s*=\s*([^']*)'[^']*'([^;]+)", cd, re.I)
    if m:
        try:
            return unquote(m.group(2).strip().strip('"'), encoding=m.group(1) or "utf-8")
        except LookupError:
            return unquote(m.group(2).strip().strip('"'))
    m = re.search(r'filename\s*=\s*"((?:[^"\\]|\\.)*)"', cd, re.I) or \
        re.search(r"filename\s*=\s*([^;]+)", cd, re.I)
    if m:
        v = m.group(1).strip().strip('"')
        try:  # servers often send UTF-8 bytes interpreted as latin-1
            v = v.encode("latin-1").decode("utf-8")
        except (UnicodeEncodeError, UnicodeDecodeError):
            pass
        return unquote(v)
    return ""


def pick_filename(final_url, headers, ctype):
    name = name_from_disposition(headers.get("Content-Disposition", ""))
    p = urlsplit(final_url)
    if not name:
        q = parse_qs(p.query)
        for key in ("filename", "file", "fn", "name", "download", "title"):
            if key in q and q[key] and os.path.splitext(q[key][0])[1]:
                name = q[key][0]
                break
    if not name:
        name = unquote(p.path.rstrip("/").split("/")[-1])
    name = sanitize_name(name)
    if not name or name.lower() in ("download", "get", "file", "dl", "index"):
        host = (p.hostname or "file").replace("www.", "").split(".")[0]
        name = sanitize_name(name or host) or "download"
    ext = os.path.splitext(name)[1].lower().lstrip(".")
    if not ext or ext in BAD_EXTS:
        new = MIME_FIX.get(ctype) or (mimetypes.guess_extension(ctype) if ctype and
                                       ctype != "application/octet-stream" else None)
        if new:
            stem = os.path.splitext(name)[0] if ext in BAD_EXTS and ext else name
            name = stem + new
    return name


# --------------------------------------------------------------------- probe
def parse_ctype(h):
    return (h.get("Content-Type", "") or "").split(";")[0].strip().lower()


def probe(url, cfg, opener=None):
    opener = opener or build_opener(cfg)
    url = resolve_url(url)
    alt = special_page_resolve(opener, url, cfg)
    if alt:
        url = alt
    last_err = None
    for attempt in range(2):                 # 2nd round = Google Drive confirm page
        resp = None
        for method, extra in (("HEAD", None), ("GET", {"Range": "bytes=0-0"})):
            try:
                resp = open_url(opener, url, cfg, method, extra)
                break
            except urllib.error.HTTPError as e:
                last_err = http_error_text(e)
                if method == "HEAD" and e.code in (400, 401, 403, 404, 405, 406, 429, 500, 501):
                    continue
                raise FetchError(last_err, 2)
            except (urllib.error.URLError, socket.timeout, OSError, http.client.HTTPException) as e:
                last_err = str(getattr(e, "reason", e))
                if method == "HEAD":
                    continue
                raise FetchError(last_err, 3)
        if resp is None:
            raise FetchError(last_err or "no response", 3)
        info = Cfg()
        info.final = resp.geturl()
        h = resp.headers
        info.ctype = parse_ctype(h)
        info.status = getattr(resp, "status", 200)
        disp = h.get("Content-Disposition", "") or ""
        info.attachment = "attachment" in disp.lower() or "filename" in disp.lower()
        size = None
        cr = h.get("Content-Range", "")
        m = re.search(r"/(\d+)\s*$", cr)
        if m:
            size = int(m.group(1))
        elif h.get("Content-Length", "").isdigit() and info.status != 206:
            size = int(h.get("Content-Length"))
        info.size = size
        ar = (h.get("Accept-Ranges", "") or "").lower()
        info.ranges = info.status == 206 or ar == "bytes"
        info.range_unknown = (ar == "")
        info.etag = h.get("ETag", "") or ""
        info.lastmod = h.get("Last-Modified", "") or ""
        info.name = pick_filename(info.final, h, info.ctype)
        info.is_html = info.ctype in HTML_TYPES and not info.attachment
        try:
            resp.close()
        except Exception:
            pass
        # Google Drive interstitial
        if info.is_html and "google.com" in (urlsplit(info.final).hostname or ""):
            r2 = open_url(opener, info.final, cfg)
            html = _read_html(r2, 400000)
            r2.close()
            nxt = drive_confirm_url(html, info.final)
            if nxt and attempt == 0:
                url = nxt
                continue
            if "quota" in html.lower() or "too many users" in html.lower():
                raise FetchError("Google Drive download quota exceeded for this file", 2)
        # servers that do not advertise ranges but support them
        if info.size and info.range_unknown and not info.ranges and not info.is_html:
            try:
                r3 = open_url(opener, info.final, cfg, "GET", {"Range": "bytes=0-0"})
                info.ranges = getattr(r3, "status", 200) == 206
                r3.close()
            except Exception:
                pass
        info.url = url
        # name has no usable extension (e.g. /download?id=7): peek at the first bytes
        if not info.is_html and not os.path.splitext(info.name)[1] and info.size != 0:
            try:
                ext = sniff_remote(opener, info, cfg)
                if ext:
                    info.name += ext
            except Exception:
                pass
        return info
    raise FetchError(last_err or "probe failed", 3)


def sniff_remote(opener, info, cfg):
    import tempfile
    r = open_url(opener, info.final, cfg, "GET", {"Range": "bytes=0-65535"})
    data = r.read(65536)
    r.close()
    if not data:
        return ""
    fd, tmp = tempfile.mkstemp(prefix="adm_sniff_")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        ext = sniff_ext(tmp)
    finally:
        try:
            os.remove(tmp)
        except OSError:
            pass
    return "" if ext in (".html", ".txt", ".xml", ".json", ".svg", ".sh") else ext


def cmd_probe(a, cfg):
    try:
        i = probe(a.url, cfg)
    except FetchError as e:
        out("kind=error")
        out("err=%s" % str(e).replace("\n", " "))
        out("code=%d" % e.code)
        return 0
    except Exception as e:
        out("kind=error")
        out("err=%s" % str(e).replace("\n", " "))
        out("code=1")
        return 0
    out("kind=%s" % ("html" if i.is_html else "file"))
    out("name=%s" % i.name)
    out("size=%s" % (i.size if i.size is not None else ""))
    out("size_h=%s" % (fmt_size(i.size) if i.size is not None else "unknown"))
    out("ctype=%s" % i.ctype)
    out("ranges=%d" % (1 if i.ranges else 0))
    out("category=%s" % category_of(i.name))
    out("final=%s" % i.final)
    return 0


# ----------------------------------------------------------- magic sniffing
def sniff_ext(path):
    """Return a file extension (with dot) from the file's real content, or ''."""
    try:
        with open(path, "rb") as f:
            b = f.read(4096)
            size = os.path.getsize(path)
            f.seek(0x8001)
            iso = f.read(5)
            f.seek(257)
            tar = f.read(5)
    except OSError:
        return ""
    if not b:
        return ""
    s = b[:16]
    if b.startswith(b"PK\x03\x04") or b.startswith(b"PK\x05\x06"):
        try:
            names = zipfile.ZipFile(path).namelist()
            nl = set(names)
            if "AndroidManifest.xml" in nl:
                return ".apk"
            if any(n.startswith("word/") for n in names):
                return ".docx"
            if any(n.startswith("xl/") for n in names):
                return ".xlsx"
            if any(n.startswith("ppt/") for n in names):
                return ".pptx"
            if "mimetype" in nl:
                try:
                    mt = zipfile.ZipFile(path).read("mimetype")[:60]
                    if b"epub" in mt:
                        return ".epub"
                    if b"opendocument.text" in mt:
                        return ".odt"
                    if b"opendocument.spreadsheet" in mt:
                        return ".ods"
                except Exception:
                    pass
            if "META-INF/MANIFEST.MF" in nl:
                return ".jar"
        except Exception:
            pass
        return ".zip"
    sigs = [
        (b"%PDF-", ".pdf"), (b"\x89PNG\r\n\x1a\n", ".png"), (b"\xff\xd8\xff", ".jpg"),
        (b"GIF87a", ".gif"), (b"GIF89a", ".gif"), (b"BM", None), (b"Rar!\x1a\x07", ".rar"),
        (b"7z\xbc\xaf\x27\x1c", ".7z"), (b"\x1f\x8b", ".gz"), (b"BZh", ".bz2"),
        (b"\xfd7zXZ\x00", ".xz"), (b"\x28\xb5\x2f\xfd", ".zst"), (b"fLaC", ".flac"),
        (b"OggS", ".ogg"), (b"FLV\x01", ".flv"),
        (b"SQLite format 3\x00", ".sqlite"), (b"{\\rtf", ".rtf"), (b"!<arch>\n", ".deb"),
        (b"\xed\xab\xee\xdb", ".rpm"), (b"wOFF", ".woff"), (b"wOF2", ".woff2"),
        (b"OTTO", ".otf"), (b"\x00\x01\x00\x00\x00", ".ttf"), (b"II*\x00", ".tif"),
        (b"MM\x00*", ".tif"), (b"\x00\x00\x01\x00", ".ico"), (b"MZ", ".exe"),
        (b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1", ".doc"), (b"ID3", ".mp3"),
        (b"\x00\x00\x01\xba", ".mpg"), (b"\x00\x00\x01\xb3", ".mpg"),
        (b"#!/", ".sh"), (b"\x1a\x45\xdf\xa3", "EBML"),
    ]
    for sig, ext in sigs:
        if b.startswith(sig):
            if ext == "EBML":
                return ".webm" if b"webm" in b[:64] else ".mkv"
            if ext is None:
                return ".bmp" if len(b) > 14 and b[6:10] == b"\x00\x00\x00\x00" else ""
            return ext
    if b[:4] == b"RIFF" and len(b) >= 12:
        t = b[8:12]
        return {b"WEBP": ".webp", b"WAVE": ".wav", b"AVI ": ".avi"}.get(t, "")
    if len(b) >= 12 and b[4:8] == b"ftyp":
        br = b[8:12]
        if br.startswith(b"M4A") or br == b"M4B ":
            return ".m4a"
        if br == b"qt  ":
            return ".mov"
        if br.startswith(b"3g"):
            return ".3gp"
        if br == b"M4V ":
            return ".m4v"
        if br in (b"heic", b"heix", b"mif1", b"msf1"):
            return ".heic"
        if br in (b"avif", b"avis"):
            return ".avif"
        return ".mp4"
    if s[:1] == b"\xff" and len(s) > 1 and (s[1] & 0xE0) == 0xE0:
        return ".aac" if (s[1] & 0xF6) == 0xF0 else ".mp3"
    if size > 564 and b[0:1] == b"\x47" and b[188:189] == b"\x47" and b[376:377] == b"\x47":
        return ".ts"
    if tar == b"ustar":
        return ".tar"
    if iso == b"CD001":
        return ".iso"
    head = b[:512].lstrip().lower()
    if head.startswith((b"<!doctype html", b"<html")) or b"<html" in head[:200]:
        return ".html"
    if head.startswith(b"<?xml"):
        return ".svg" if b"<svg" in b[:1024].lower() else ".xml"
    if head.startswith(b"<svg"):
        return ".svg"
    if head.startswith((b"{", b"[")):
        try:
            with open(path, "rb") as f:
                json.loads(f.read(2 * 1024 * 1024).decode("utf-8"))
            return ".json"
        except Exception:
            pass
    try:
        txt = b.decode("utf-8")
        if sum(1 for c in txt if c.isprintable() or c in "\r\n\t") / max(len(txt), 1) > 0.97:
            return ".txt"
    except UnicodeDecodeError:
        pass
    return ""


def unique_path(path):
    if not os.path.exists(path):
        return path
    base, ext = os.path.splitext(path)
    i = 1
    while os.path.exists("%s (%d)%s" % (base, i, ext)):
        i += 1
    return "%s (%d)%s" % (base, i, ext)


def fix_extension(path):
    """Rename `path` if its extension is missing/wrong. Returns the (new) path."""
    if not os.path.isfile(path) or path.endswith(".part"):
        return path
    base, ext = os.path.splitext(path)
    e = ext.lower().lstrip(".")
    if e not in BAD_EXTS:
        return path
    found = sniff_ext(path)
    if not found:
        return path
    if e in SCRIPTY:
        if found in TEXTY:          # a real .php/.html source file: leave it alone
            return path
    elif e and found == ".html":    # e.g. unknown_video that holds an error page
        return path
    stem = base if e else path
    new = unique_path(stem + found)
    if new == path:
        return path
    try:
        os.rename(path, new)
        return new
    except OSError:
        return path


def cmd_fixext(a, cfg):
    target = a.url
    changed = 0
    if os.path.isfile(target):
        new = fix_extension(target)
        if new != target:
            out("%s -> %s" % (os.path.basename(target), os.path.basename(new)))
            changed += 1
        out(new)
        return 0
    for root, dirs, files in os.walk(target):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for fn in files:
            if fn.startswith(".") or fn.endswith((".part", ".adm")):
                continue
            p = os.path.join(root, fn)
            new = fix_extension(p)
            if new != p:
                out("%s -> %s" % (fn, os.path.basename(new)))
                changed += 1
    out("DONE %d" % changed)
    return 0


# ---------------------------------------------------------------- limiter etc
def parse_rate(s):
    if not s:
        return 0
    m = re.match(r"^\s*([\d.]+)\s*([kKmMgG]?)", str(s))
    if not m:
        return 0
    mult = {"": 1, "k": 1024, "m": 1024 ** 2, "g": 1024 ** 3}[m.group(2).lower()]
    return int(float(m.group(1)) * mult)


class Limiter(object):
    def __init__(self, rate):
        self.rate = rate
        self.lock = threading.Lock()
        self.nxt = time.monotonic()

    def take(self, n):
        if not self.rate:
            return
        with self.lock:
            now = time.monotonic()
            if self.nxt < now:
                self.nxt = now
            self.nxt += float(n) / self.rate
            wait = self.nxt - now - 0.5
        if wait > 0:
            time.sleep(wait)


class Progress(object):
    def __init__(self, total, start=0):
        self.total = total
        self.done = start
        self.start = start
        self.lock = threading.Lock()
        self.samples = deque([(time.monotonic(), start)])
        self.t0 = time.monotonic()

    def add(self, n):
        with self.lock:
            self.done += n

    def speed(self):
        now = time.monotonic()
        with self.lock:
            d = self.done
            self.samples.append((now, d))
            while len(self.samples) > 2 and now - self.samples[0][0] > 4.0:
                self.samples.popleft()
            t0, d0 = self.samples[0]
        dt = now - t0
        return (d - d0) / dt if dt > 0.2 else 0.0

    def final_line(self):
        el = max(time.monotonic() - self.t0, 0.001)
        moved = max(self.done - self.start, 0)
        return "[download] 100.0%% of %s at %s/s ETA 00:00" % (
            fmt_size(self.done), fmt_size(moved / el))

    def line(self):
        sp = self.speed()
        d = self.done
        if self.total:
            pct = min(100.0, d * 100.0 / self.total)
            eta = ((self.total - d) / sp) if sp > 1 else None
            return "[download] %5.1f%% of %s at %s/s ETA %s" % (
                pct, fmt_size(self.total), fmt_size(sp), fmt_eta(eta))
        return "[download]   ??%% of %s at %s/s ETA --:--" % (fmt_size(d), fmt_size(sp))


class Reporter(threading.Thread):
    def __init__(self, prog):
        threading.Thread.__init__(self)
        self.daemon = True
        self.prog = prog
        self.stop_ev = threading.Event()

    def run(self):
        while not self.stop_ev.wait(0.5):
            out(self.prog.line())

    def stop(self):
        self.stop_ev.set()


# ------------------------------------------------------------- state / resume
def state_path(part):
    return part + ".adm"


def load_state(part):
    try:
        with open(state_path(part)) as f:
            return json.load(f)
    except Exception:
        return None


def save_state(part, st):
    tmp = state_path(part) + ".tmp"
    try:
        with open(tmp, "w") as f:
            json.dump(st, f)
        os.replace(tmp, state_path(part))
    except OSError:
        pass


def clear_state(part):
    for p in (state_path(part), state_path(part) + ".tmp"):
        try:
            os.remove(p)
        except OSError:
            pass


# --------------------------------------------------------- segmented download
def segmented(info, part, cfg, limiter):
    size, conn = info.size, cfg.conn
    ck = max(1 << 20, min(8 << 20, (size // (conn * 4)) // (1 << 20) * (1 << 20) or (1 << 20)))
    n = (size + ck - 1) // ck
    st = load_state(part)
    done = set()
    ident = {"size": size, "chunk": ck, "etag": info.etag, "lm": info.lastmod}
    if st and all(st.get(k) == v for k, v in ident.items()) and os.path.exists(part):
        done = set(st.get("done", []))
    else:
        clear_state(part)
        if os.path.exists(part):
            os.remove(part)
    fd = os.open(part, os.O_RDWR | os.O_CREAT, 0o644)
    if os.fstat(fd).st_size != size:
        os.ftruncate(fd, size)

    def clen(i):
        return min(size, (i + 1) * ck) - i * ck

    start_bytes = sum(clen(i) for i in done)
    prog = Progress(size, start_bytes)
    pending = deque(i for i in range(n) if i not in done)
    lock = threading.Lock()
    stop = threading.Event()
    failure = []
    last_save = [time.monotonic()]

    def persist(force=False):
        if force or time.monotonic() - last_save[0] > 1.5:
            last_save[0] = time.monotonic()
            st2 = dict(ident)
            st2["done"] = sorted(done)
            save_state(part, st2)

    def fetch_chunk(opener, i):
        s0 = i * ck
        e0 = s0 + clen(i) - 1
        delay = 1.0
        for attempt in range(cfg.retries):
            if stop.is_set():
                return False
            got = 0
            try:
                extra = {"Range": "bytes=%d-%d" % (s0, e0)}
                if info.etag:
                    extra["If-Range"] = info.etag
                resp = open_url(opener, info.final, cfg, "GET", extra)
                if getattr(resp, "status", 200) != 206:
                    resp.close()
                    raise SegFail("server ignored Range request")
                pos = s0
                while pos <= e0 and not stop.is_set():
                    data = resp.read(min(65536, e0 - pos + 1))
                    if not data:
                        raise IOError("connection closed early")
                    limiter.take(len(data))
                    os.pwrite(fd, data, pos)
                    pos += len(data)
                    got += len(data)
                    prog.add(len(data))
                resp.close()
                if stop.is_set():
                    prog.add(-got)
                    return False
                with lock:
                    done.add(i)
                    persist()
                return True
            except urllib.error.HTTPError as e:
                prog.add(-got)
                if e.code in (401, 403, 404, 410, 416) and attempt >= 1:
                    raise SegFail(http_error_text(e))
                time.sleep(delay * (3 if e.code == 429 else 1))
                delay = min(delay * 2, 15)
            except SegFail:
                prog.add(-got)
                raise
            except (urllib.error.URLError, socket.timeout, OSError,
                    http.client.HTTPException, ssl.SSLError):
                prog.add(-got)
                time.sleep(delay)
                delay = min(delay * 2, 15)
        failure.append("chunk %d failed after %d retries" % (i, cfg.retries))
        return False

    def worker():
        try:
            opener = build_opener(cfg)
            while not stop.is_set():
                with lock:
                    if not pending:
                        return
                    i = pending.popleft()
                if not fetch_chunk(opener, i):
                    stop.set()
                    return
        except SegFail as e:
            failure.append("SEG:" + str(e))
            stop.set()
        except Exception as e:  # noqa
            failure.append(str(e))
            stop.set()

    rep = Reporter(prog)
    rep.start()
    threads = [threading.Thread(target=worker) for _ in range(min(conn, max(1, len(pending))))]
    for t in threads:
        t.daemon = True
        t.start()
    try:
        while any(t.is_alive() for t in threads):
            for t in threads:
                t.join(0.3)
    except KeyboardInterrupt:
        stop.set()
        with lock:
            persist(True)
        rep.stop()
        os.close(fd)
        raise
    rep.stop()
    with lock:
        persist(True)
    os.close(fd)
    if len(done) != n:
        msg = failure[0] if failure else "download incomplete"
        if msg.startswith("SEG:"):
            raise SegFail(msg[4:])
        raise FetchError(msg, 3)
    out(prog.final_line())


# ------------------------------------------------------------ single stream
def single(info, part, cfg, limiter):
    size = info.size
    ident = {"size": size, "etag": info.etag, "lm": info.lastmod, "single": True}
    pos = 0
    st = load_state(part)
    if os.path.exists(part):
        if info.ranges and st and all(st.get(k) == v for k, v in ident.items()):
            pos = os.path.getsize(part)
            if size is not None and pos > size:
                pos = 0
        if pos == 0:
            os.remove(part)
    save_state(part, ident)
    opener = build_opener(cfg)
    prog = Progress(size, pos)
    rep = Reporter(prog)
    rep.start()
    delay = 1.0
    try:
        for attempt in range(cfg.retries):
            try:
                extra = {"Range": "bytes=%d-" % pos} if pos else None
                resp = open_url(opener, info.final, cfg, "GET", extra)
                status = getattr(resp, "status", 200)
                if pos and status != 206:
                    resp.close()
                    pos = 0
                    prog.add(-prog.done)
                    if os.path.exists(part):
                        os.remove(part)
                    continue
                if status == 200 and size is None:
                    cl = resp.headers.get("Content-Length", "")
                    if cl.isdigit():
                        size = int(cl)
                        prog.total = size
                with open(part, "ab" if pos else "wb") as f:
                    while True:
                        data = resp.read(65536)
                        if not data:
                            break
                        limiter.take(len(data))
                        f.write(data)
                        pos += len(data)
                        prog.add(len(data))
                resp.close()
                if size is not None and pos < size:
                    raise IOError("connection closed early")
                rep.stop()
                prog.done = pos
                out(prog.final_line())
                return
            except urllib.error.HTTPError as e:
                if e.code in (401, 403, 404, 410):
                    raise FetchError(http_error_text(e), 2)
                if e.code == 416 and size is not None and pos >= size:
                    rep.stop()
                    return
                time.sleep(delay * (3 if e.code == 429 else 1))
                delay = min(delay * 2, 15)
            except (urllib.error.URLError, socket.timeout, OSError,
                    http.client.HTTPException, ssl.SSLError) as e:
                if not info.ranges:                # cannot resume: start over
                    pos = 0
                    prog.add(-prog.done)
                else:
                    pos = os.path.getsize(part) if os.path.exists(part) else 0
                    prog.done = pos
                if attempt == cfg.retries - 1:
                    raise FetchError(str(getattr(e, "reason", e)), 3)
                time.sleep(delay)
                delay = min(delay * 2, 15)
        raise FetchError("download failed after %d retries" % cfg.retries, 3)
    finally:
        rep.stop()


# ----------------------------------------------------------------------- get
def cmd_get(a, cfg):
    info = probe(a.url, cfg)
    if info.is_html and not a.force:
        raise FetchError("this link opens a web page, not a file", 4)
    name = sanitize_name(a.name) if a.name else info.name
    if a.name and not os.path.splitext(name)[1]:
        name += os.path.splitext(info.name)[1]
    os.makedirs(a.outdir, exist_ok=True)
    final = os.path.join(a.outdir, name)
    # already downloaded?  same name + same size -> done, otherwise pick a free name
    cand, i = final, 0
    while os.path.exists(cand):
        if info.size is not None and os.path.getsize(cand) == info.size:
            out("[adm] already downloaded: %s" % os.path.basename(cand))
            out(cand)
            return 0
        i += 1
        b, e = os.path.splitext(final)
        cand = "%s (%d)%s" % (b, i, e)
    final = cand
    part = final + ".part"
    out("[adm] name=%s" % os.path.basename(final))
    out("[adm] size=%s ranges=%s" % (fmt_size(info.size) if info.size is not None else "unknown",
                                       "yes" if info.ranges else "no"))
    limiter = Limiter(parse_rate(a.rate))
    if info.size == 0:
        open(part, "wb").close()
    else:
        use_seg = (info.size and info.ranges and info.size >= MIN_SEGMENT_SIZE
                   and cfg.conn > 1 and hasattr(os, "pwrite"))
        if use_seg:
            try:
                segmented(info, part, cfg, limiter)
            except SegFail as e:
                out("[adm] parallel mode refused (%s) - using one connection" % e)
                clear_state(part)
                if os.path.exists(part):
                    os.remove(part)
                single(info, part, cfg, limiter)
        else:
            single(info, part, cfg, limiter)
    if os.path.exists(part) and info.size is not None and os.path.getsize(part) != info.size:
        raise FetchError("size mismatch (%d of %d bytes)" % (os.path.getsize(part), info.size), 3)
    final = unique_path(final) if os.path.exists(final) else final
    os.replace(part, final)
    clear_state(part)
    final = fix_extension(final)
    out(os.path.abspath(final))
    return 0


# ---------------------------------------------------------------------- scan
class LinkParser(HTMLParser):
    def __init__(self):
        HTMLParser.__init__(self)
        self.links = []
        self.base = None

    def handle_starttag(self, tag, attrs):
        d = dict(attrs)
        if tag == "base" and d.get("href"):
            self.base = d["href"]
        for key in ("href", "src", "data-src", "data-url", "data-href", "data-download"):
            v = d.get(key)
            if v and tag in ("a", "source", "video", "audio", "embed", "link", "img",
                             "iframe", "object", "button", "div", "span"):
                if tag == "link" and "stylesheet" in (d.get("rel") or ""):
                    continue
                self.links.append((v, "download" in d))


def cmd_scan(a, cfg):
    opener = build_opener(cfg)
    try:
        resp = open_url(opener, resolve_url(a.url), cfg)
    except Exception as e:
        out("ERROR: %s" % e)
        return 1
    base = resp.geturl()
    if parse_ctype(resp.headers) not in HTML_TYPES:
        out("ERROR: not an HTML page")
        return 1
    html = _read_html(resp)
    resp.close()
    p = LinkParser()
    try:
        p.feed(html)
    except Exception:
        pass
    # also catch absolute links hiding in scripts / text
    raw = re.findall(r"https?://[^\s\"'<>)\\]+", html)
    cands = [(l, False) for l in raw] + p.links
    seen, rows = set(), []
    for link, forced in cands:
        link = link.strip().replace("&amp;", "&")
        if not link or link.startswith(("#", "javascript:", "mailto:", "tel:", "data:")):
            continue
        u = urljoin(p.base and urljoin(base, p.base) or base, link)
        if urlsplit(u).scheme not in ("http", "https"):
            continue
        u = u.split("#")[0]
        if u in seen:
            continue
        path = unquote(urlsplit(u).path)
        ext = os.path.splitext(path)[1].lower().lstrip(".")
        if ext in WEB_EXTS or (not ext and not forced):
            continue
        if not forced and ext not in EXT2CAT:
            continue
        seen.add(u)
        nm = sanitize_name(path.split("/")[-1]) or "file"
        rows.append((category_of(nm), nm, u))
    order = {c: i for i, c in enumerate(["Apps", "Archives", "Documents", "Video", "Audio",
                                          "Images", "Fonts", "Other"])}
    rows.sort(key=lambda r: (order.get(r[0], 9), r[1].lower()))
    for cat, nm, u in rows[:200]:
        out("%s\t%s\t%s" % (cat, nm, u))
    return 0


# ---------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["probe", "get", "scan", "fixext"])
    ap.add_argument("url")
    ap.add_argument("--outdir", default=".")
    ap.add_argument("--name", default="")
    ap.add_argument("--conn", type=int, default=8)
    ap.add_argument("--rate", default="")
    ap.add_argument("--cookies", default="")
    ap.add_argument("--proxy", default="")
    ap.add_argument("--ua", default=UA)
    ap.add_argument("--referer", default="")
    ap.add_argument("--header", action="append", default=[])
    ap.add_argument("--retries", type=int, default=8)
    ap.add_argument("--timeout", type=int, default=30)
    ap.add_argument("--insecure", action="store_true")
    ap.add_argument("--force", action="store_true")
    a = ap.parse_args()

    def _stop(sig, frm):
        raise KeyboardInterrupt
    signal.signal(signal.SIGINT, _stop)
    signal.signal(signal.SIGTERM, _stop)

    cfg = Cfg()
    cfg.conn = max(1, min(16, a.conn))
    cfg.proxy = a.proxy
    cfg.ua = a.ua
    cfg.referer = a.referer
    cfg.headers = a.header
    cfg.retries = max(1, a.retries)
    cfg.timeout = a.timeout if a.cmd != "probe" else min(a.timeout, 12)
    cfg.insecure = a.insecure
    cfg.jar = None
    if a.cookies and os.path.isfile(a.cookies) and os.path.getsize(a.cookies) > 0:
        try:
            jar = http.cookiejar.MozillaCookieJar()
            jar.load(a.cookies, ignore_discard=True, ignore_expires=True)
            for c in jar:                    # expires=0 means "session cookie" in cookies.txt
                if not c.expires:
                    c.expires = None
                    c.discard = True
            cfg.jar = jar
        except Exception:
            cfg.jar = None
    try:
        if a.cmd == "probe":
            return cmd_probe(a, cfg)
        if a.cmd == "get":
            return cmd_get(a, cfg)
        if a.cmd == "scan":
            return cmd_scan(a, cfg)
        return cmd_fixext(a, cfg)
    except FetchError as e:
        out("ERROR: %s" % e)
        return e.code
    except KeyboardInterrupt:
        out("ERROR: cancelled (partial data kept for resume)")
        return 130
    except ssl.SSLError as e:
        out("ERROR: SSL problem: %s" % e)
        return 6
    except Exception as e:
        out("ERROR: %s" % e)
        return 1


if __name__ == "__main__":
    sys.exit(main())
PYEOF
    if command -v cmp &>/dev/null && cmp -s "${FETCHER}.new" "$FETCHER" 2>/dev/null; then
        rm -f "${FETCHER}.new"
    else
        mv -f "${FETCHER}.new" "$FETCHER"
    fi
}
_write_fetcher

[ ! -f "$STATS_FILE" ]     && echo '{"total_downloads":0,"total_time":0}' > "$STATS_FILE"
[ ! -f "$PLAYER_SETTINGS" ] && echo '{"volume":80}' > "$PLAYER_SETTINGS"
[ ! -f "$HISTORY_FILE" ]   && echo '[]' > "$HISTORY_FILE"

[ ! -f "$SETTINGS_FILE" ] && cat > "$SETTINGS_FILE" << 'SETEOF'
{
  "speed_limit": "",
  "proxy": "",
  "save_thumbnail": false,
  "save_subtitle": false,
  "embed_metadata": true,
  "sponsorblock": false,
  "subtitle_lang": "en",
  "video_password": "",
  "use_aria2c": true,
  "update_url": "",
  "filename_template": "%(title)s.%(ext)s",
  "max_parallel": 1,
  "auto_compress": false,
  "telegram_bot_token": "",
  "telegram_chat_id": "",
  "wifi_only": false,
  "data_saver": false,
  "app_pin_hash": "",
  "language": "en",
  "sync_quality": "5",
  "file_connections": 8,
  "file_layout": "type"
}
SETEOF

# ================================================================
# SETTINGS — cached in memory, single python3 call at load time
# ================================================================

# In-memory cache (associative array)
declare -A _CFG

_cfg_load() {
    local RAW
    RAW=$(python3 - "$SETTINGS_FILE" << 'PYEOF' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    for k, v in d.items():
        if isinstance(v, bool): print(f"{k}={'true' if v else 'false'}")
        else: print(f"{k}={v}")
except: pass
PYEOF
)
    while IFS='=' read -r k v; do
        [ -n "$k" ] && _CFG["$k"]="$v"
    done <<< "$RAW"
}

get_setting() {
    echo "${_CFG[$1]:-}"
}

set_setting() {
    local KEY="$1" VAL="$2"
    _CFG["$KEY"]="$VAL"
    python3 - "$KEY" "$VAL" "$SETTINGS_FILE" << 'PYEOF' 2>/dev/null
import json, sys
key = sys.argv[1]; val = sys.argv[2]; f = sys.argv[3]
try:    d = json.load(open(f))
except: d = {}
if   val.lower() == 'true':  val = True
elif val.lower() == 'false': val = False
elif val.isdigit():           val = int(val)
d[key] = val
json.dump(d, open(f, 'w'), indent=2)
PYEOF
}

# Load settings into memory once at startup
_cfg_load

# ================================================================
# LOGGING — persistent event/error log for troubleshooting
# ================================================================
_get_filename_template() {
    local T; T=$(get_setting filename_template)
    [ -z "$T" ] && T="%(title)s.%(ext)s"
    echo "$T"
}

log_msg() {
    local LEVEL="$1"; shift
    local MSG="$*"
    mkdir -p "$DATA_DIR" 2>/dev/null
    printf '[%s] %-5s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$LEVEL" "$MSG" >> "$LOG_FILE" 2>/dev/null
    # Rotate: keep the log from growing forever
    local _LC; _LC=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "${_LC:-0}" -gt 1000 ]; then
        tail -n 500 "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null && mv -f "${LOG_FILE}.tmp" "$LOG_FILE" 2>/dev/null
    fi
}

# ================================================================
# FIRST TIME SETUP
# ================================================================
first_time_setup() {
    clear 2>/dev/null
    echo ""
    echo -e "${C}  ================================================================${N}"
    echo -e "${W}          ADM — A. Professor's Download Manager — First Time Setup${N}"
    echo -e "${C}  ================================================================${N}"
    echo -e "${Y}  Setting up everything. This will take a few minutes...${N}"
    echo -e "${C}  ================================================================${N}"
    echo ""

    echo -e "${C}  [1/7] Updating packages...${N}"
    pkg update -y -q 2>/dev/null
    pkg upgrade -y -q 2>/dev/null
    echo -e "${G}  [OK] Packages updated${N}\n"

    echo -e "${C}  [2/7] Setting up storage...${N}"
    if [ ! -d "/sdcard/Download" ]; then
        termux-setup-storage
        sleep 3
    fi
    mkdir -p "$BASE_SAVE" "$DATA_DIR"
    echo -e "${G}  [OK] Storage ready${N}\n"

    echo -e "${C}  [3/7] Installing core packages...${N}"
    pkg install python ffmpeg nodejs ncurses-utils -y -q 2>/dev/null
    echo -e "${G}  [OK] Core packages ready${N}\n"

    echo -e "${C}  [4/7] Installing yt-dlp...${N}"
    python -m ensurepip --upgrade -q 2>/dev/null || true
    pip install yt-dlp -q 2>/dev/null || pip3 install yt-dlp -q 2>/dev/null
    echo -e "${G}  [OK] yt-dlp ready${N}\n"

    echo -e "${C}  [5/7] Installing mpv (audio player)...${N}"
    if [ "$OS_TYPE" = "android" ]; then
        pkg install mpv -y -q 2>/dev/null
    else
        sudo apt install mpv -y -q 2>/dev/null || \
        sudo pacman -S mpv --noconfirm -q 2>/dev/null || true
    fi
    echo -e "${G}  [OK] mpv ready${N}\n"

    echo -e "${C}  [6/7] Extras...${N}"
    if [ "$OS_TYPE" = "linux" ]; then
        sudo apt install tmux ncurses-bin socat -y -q 2>/dev/null || \
        sudo pacman -S tmux socat --noconfirm -q 2>/dev/null || true
        echo -e "${G}  [OK] Linux extras ready${N}\n"
    else
        pkg install socat termux-api -y -q 2>/dev/null || true
        echo -e "${G}  [6/7] Android extras ready${N}\n"
    fi

    echo -e "${C}  [7/7] Finalizing...${N}"
    touch "$SETUP_FLAG"
    echo -e "${G}  [OK] Setup complete${N}\n"

    echo -e "${C}  ================================================================${N}"
    echo -e "${G}          All done! Starting ADM...${N}"
    echo -e "${C}  ================================================================${N}"
    sleep 2
}

if [ ! -f "$SETUP_FLAG" ]; then
    first_time_setup
else
    command -v yt-dlp &>/dev/null || {
        echo -e "${Y}  yt-dlp missing, reinstalling...${N}"
        pip install yt-dlp -q 2>/dev/null || pip3 install yt-dlp -q 2>/dev/null
    }
    command -v ffmpeg &>/dev/null || {
        echo -e "${Y}  ffmpeg missing, reinstalling...${N}"
        [ "$OS_TYPE" = "android" ] && pkg install ffmpeg -y -q || \
        sudo apt install ffmpeg -y -q 2>/dev/null
    }
fi

# ================================================================
# AUTO INSTALL
# ================================================================
auto_install() {
    local TOOL="$1"
    echo -e "${Y}  Installing ${TOOL}...${N}"
    case "$TOOL" in
        yt-dlp)      pip3 install yt-dlp -q 2>/dev/null || pip install yt-dlp -q ;;
        ffmpeg)      [ "$OS_TYPE" = "android" ] && pkg install ffmpeg -y -q || sudo apt install ffmpeg -y -q 2>/dev/null ;;
        python3)     [ "$OS_TYPE" = "android" ] && pkg install python -y -q  || sudo apt install python3 python3-pip -y -q 2>/dev/null ;;
        nodejs)      [ "$OS_TYPE" = "android" ] && pkg install nodejs -y -q  || sudo apt install nodejs -y -q 2>/dev/null ;;
        tmux)        [ "$OS_TYPE" = "android" ] && pkg install tmux -y -q    || sudo apt install tmux -y -q 2>/dev/null ;;
        mpv)         [ "$OS_TYPE" = "android" ] && pkg install mpv -y -q     || sudo apt install mpv -y -q 2>/dev/null ;;
        socat)       [ "$OS_TYPE" = "android" ] && pkg install socat -y -q   || sudo apt install socat -y -q 2>/dev/null ;;
        termux-api)  [ "$OS_TYPE" = "android" ] && pkg install termux-api -y -q 2>/dev/null || true ;;
        aria2c)      [ "$OS_TYPE" = "android" ] && pkg install aria2 -y -q 2>/dev/null || \
                     sudo apt install aria2 -y -q 2>/dev/null || \
                     sudo pacman -S aria2 --noconfirm -q 2>/dev/null || true ;;
        qrencode)    [ "$OS_TYPE" = "android" ] && pkg install libqrencode-tools -y -q 2>/dev/null || \
                     sudo apt install qrencode -y -q 2>/dev/null || \
                     sudo pacman -S qrencode --noconfirm -q 2>/dev/null || true ;;
    esac
    echo -e "${G}  [OK] ${TOOL} ready${N}"
}

check_and_fix_all() {
    echo -e "\n${DIM}${C}  Checking dependencies...${N}"
    command -v python3 &>/dev/null || auto_install python3
    command -v yt-dlp  &>/dev/null || auto_install yt-dlp
    command -v ffmpeg  &>/dev/null || auto_install ffmpeg
    command -v node    &>/dev/null || auto_install nodejs
    command -v mpv     &>/dev/null || auto_install mpv
    if [ "$OS_TYPE" = "linux" ]; then
        command -v tmux  &>/dev/null || auto_install tmux
    fi
    # aria2c is optional — speeds up downloads but never blocks the app if it fails
    if [ "$(get_setting use_aria2c)" != "false" ]; then
        command -v aria2c &>/dev/null || auto_install aria2c
    fi
    echo -e "${G}  All systems ready${N}\n"
}

auto_update_ytdlp() {
    echo -e "${DIM}${C}  Syncing yt-dlp...${N}"
    pip3 install -U yt-dlp -q 2>/dev/null || pip install -U yt-dlp -q 2>/dev/null
    echo -e "${G}  yt-dlp synced${N}"
}

# ================================================================
# DOWNLOAD SPEED TEST
# ================================================================
run_speed_test() {
    clear 2>/dev/null
    local TW; TW=$(tput cols 2>/dev/null || echo 70)
    printf "\033[38;5;33m"; _repeat_char '━' "$TW"; printf "\033[0m\n"
    printf "  \033[1;97mDOWNLOAD SPEED TEST\033[0m\n"
    printf "\033[38;5;240m"; _repeat_char '─' "$TW"; printf "\033[0m\n\n"
    info_msg "Testing connection speed..."
    local START END BYTES
    local TEST_URL="https://speed.cloudflare.com/__down?bytes=5000000"
    START=$(date +%s%3N)
    BYTES=$(curl -s -o /dev/null -w "%{size_download}" --max-time 10 "$TEST_URL" 2>/dev/null)
    END=$(date +%s%3N)
    if [ -z "$BYTES" ] || [ "$BYTES" -le 0 ]; then
        error_msg "Speed test failed."; echo -ne "\n  \033[2mPress Enter...\033[0m"; read -r; return 1
    fi
    local ELAPSED=$(( END - START )); [ "$ELAPSED" -eq 0 ] && ELAPSED=1
    local SPEED_KBPS=$(( BYTES * 8 / ELAPSED ))
    local MBPS_INT=$(( SPEED_KBPS / 1000 ))
    local MBPS_DEC=$(( (SPEED_KBPS % 1000) / 100 ))
    local RATING RATING_CLR
    if   [ "$SPEED_KBPS" -lt 5000  ]; then RATING="Slow — 360p max";    RATING_CLR=196
    elif [ "$SPEED_KBPS" -lt 15000 ]; then RATING="OK — 720p";          RATING_CLR=208
    elif [ "$SPEED_KBPS" -lt 30000 ]; then RATING="Good — 1080p";       RATING_CLR=226
    else                                   RATING="Fast — 4K ok";       RATING_CLR=46
    fi
    local BAR_W=40 FILL=$(( SPEED_KBPS / 2500 )) i
    [ "$FILL" -gt 40 ] && FILL=40
    printf "\n  "
    for (( i=0; i<BAR_W; i++ )); do
        if [ "$i" -lt "$FILL" ]; then
            if   [ "$i" -lt 10 ]; then printf "\033[38;5;196m█\033[0m"
            elif [ "$i" -lt 20 ]; then printf "\033[38;5;208m█\033[0m"
            elif [ "$i" -lt 30 ]; then printf "\033[38;5;226m█\033[0m"
            else                       printf "\033[38;5;46m█\033[0m"
            fi
        else
            printf "\033[38;5;238m▒\033[0m"
        fi
    done
    printf "\n\n"
    printf "  \033[38;5;244mSpeed  \033[0m\033[1;97m%d.%d Mbps\033[0m\n" "$MBPS_INT" "$MBPS_DEC"
    printf "  \033[38;5;244mRating \033[0m\033[38;5;%sm%s\033[0m\n\n" "$RATING_CLR" "$RATING"
    printf "\033[38;5;240m"; _repeat_char '─' "$TW"; printf "\033[0m\n"
    echo -ne "  \033[2mPress Enter to continue...\033[0m"; read -r
}

# ================================================================
# STORAGE MANAGER
# ================================================================
show_storage_manager() {
    clear 2>/dev/null
    local TW; TW=$(tput cols 2>/dev/null || echo 70)
    printf "\033[38;5;33m"; _repeat_char '━' "$TW"; printf "\033[0m\n"
    printf "  \033[1;97mSTORAGE MANAGER\033[0m\n"
    printf "\033[38;5;240m"; _repeat_char '─' "$TW"; printf "\033[0m\n\n"

    mkdir -p "$BASE_SAVE" 2>/dev/null
    local TOTAL_SZ; TOTAL_SZ=$(du -sh "$BASE_SAVE" 2>/dev/null | cut -f1)
    printf "  \033[38;5;244mLocation \033[0m\033[1;37m%s\033[0m\n" "$BASE_SAVE"
    printf "  \033[38;5;244mTotal    \033[0m\033[1;37m%s\033[0m\n\n" "${TOTAL_SZ:-0}"

    printf "  \033[1;37m%-16s %10s %8s\033[0m\n" "Platform" "Size" "Files"
    printf "\033[38;5;240m"; _repeat_char '─' "$TW"; printf "\033[0m\n"

    local FOLDER SZ CNT
    if [ -d "$BASE_SAVE" ]; then
        for FOLDER in "$BASE_SAVE"/*/; do
            [ -d "$FOLDER" ] || continue
            SZ=$(du -sh "$FOLDER" 2>/dev/null | cut -f1)
            CNT=$(find "$FOLDER" -type f 2>/dev/null | wc -l)
            printf "  %-16s %10s %8s\n" "$(basename "$FOLDER")" "${SZ:-0}" "$CNT"
        done
    fi
    printf "\033[38;5;240m"; _repeat_char '─' "$TW"; printf "\033[0m\n"

    echo ""
    echo -e "  ${W}1${N}  Delete files older than 30 days"
    echo -e "  ${W}2${N}  Delete files older than 60 days"
    echo -e "  ${W}3${N}  Delete files older than 90 days"
    echo ""
    echo -ne "  ${Y}Select (1-3 / Enter=back): ${N}"
    read -r OPT
    local DAYS=""
    case "$OPT" in
        1) DAYS=30 ;; 2) DAYS=60 ;; 3) DAYS=90 ;;
        *) return ;;
    esac
    local N_OLD; N_OLD=$(find "$BASE_SAVE" -type f -mtime "+${DAYS}" 2>/dev/null | wc -l)
    if [ "$N_OLD" -eq 0 ]; then
        info_msg "No files older than ${DAYS} days."
        sleep 2; return
    fi
    echo -ne "  ${R}Delete ${N_OLD} file(s) older than ${DAYS} days? Type YES: ${N}"
    read -r CONFIRM
    if [ "$CONFIRM" = "YES" ]; then
        find "$BASE_SAVE" -type f -mtime "+${DAYS}" -delete 2>/dev/null
        log_msg "INFO" "Storage cleanup: removed ${N_OLD} files older than ${DAYS}d"
        success_msg "Removed ${N_OLD} file(s)."
    else
        info_msg "Cancelled."
    fi
    sleep 2
}

# ================================================================
# HEALTH CHECK — "adm doctor"
# ================================================================
run_doctor() {
    clear 2>/dev/null
    local TW; TW=$(tput cols 2>/dev/null || echo 70)
    printf "\033[38;5;33m"; _repeat_char '━' "$TW"; printf "\033[0m\n"
    printf "  \033[1;97mADM HEALTH CHECK\033[0m\n"
    printf "\033[38;5;240m"; _repeat_char '─' "$TW"; printf "\033[0m\n\n"

    local FAILS=0

    _doc_check() {
        local NAME="$1" CMD="$2" REQUIRED="$3"
        if eval "$CMD" &>/dev/null; then
            printf "  \033[38;5;46m[ OK ]\033[0m  %s\n" "$NAME"
        else
            if [ "$REQUIRED" = "req" ]; then
                printf "  \033[38;5;196m[FAIL]\033[0m  %s\n" "$NAME"
                FAILS=$(( FAILS + 1 ))
            else
                printf "  \033[38;5;208m[ - ]\033[0m   %s \033[2m(optional)\033[0m\n" "$NAME"
            fi
        fi
    }

    _doc_check "python3 installed"    "command -v python3" "req"
    _doc_check "yt-dlp installed"     "command -v yt-dlp"  "req"
    _doc_check "ffmpeg installed"     "command -v ffmpeg"  "req"
    _doc_check "node installed"       "command -v node"    "opt"
    _doc_check "mpv installed"        "command -v mpv"     "opt"
    _doc_check "aria2c installed"     "command -v aria2c"  "opt"
    _doc_check "file engine (any file type)" "[ -s '${FETCHER}' ] && python3 -c \"import ast,sys; ast.parse(open(sys.argv[1]).read())\" '${FETCHER}'" "req"
    [ "$OS_TYPE" = "linux" ] && _doc_check "tmux installed" "command -v tmux" "req"

    echo ""
    _doc_check "Internet connection"  "curl -sI --max-time 5 https://google.com" "req"
    _doc_check "Save folder writable" "touch '${BASE_SAVE}/.adm_write_test' && rm -f '${BASE_SAVE}/.adm_write_test'" "req"
    _doc_check "Data folder writable" "touch '${DATA_DIR}/.adm_write_test' && rm -f '${DATA_DIR}/.adm_write_test'"   "req"

    echo ""
    local FREE_SPACE; FREE_SPACE=$(df -h "$BASE_SAVE" 2>/dev/null | awk 'NR==2{print $4}')
    printf "  \033[38;5;244mFree space  \033[0m\033[1;37m%s\033[0m\n" "${FREE_SPACE:-unknown}"
    printf "  \033[38;5;244mADM version \033[0m\033[1;37m%s\033[0m\n" "$VERSION"
    local _YTV; _YTV=$(yt-dlp --version 2>/dev/null)
    printf "  \033[38;5;244myt-dlp ver  \033[0m\033[1;37m%s\033[0m\n" "${_YTV:-unknown}"

    echo ""
    printf "\033[38;5;240m"; _repeat_char '─' "$TW"; printf "\033[0m\n"
    if [ "$FAILS" -eq 0 ]; then
        printf "  \033[38;5;46mAll required checks passed. ADM is healthy.\033[0m\n"
        log_msg "INFO" "Health check: all OK"
    else
        printf "  \033[38;5;196m%d required check(s) failed — fix these before downloading.\033[0m\n" "$FAILS"
        log_msg "WARN" "Health check: ${FAILS} failing checks"
    fi
    echo -ne "\n  \033[2mPress Enter to continue...\033[0m"; read -r
}

# ================================================================
# CLIPBOARD AUTO-DETECT
# ================================================================
check_clipboard() {
    local CLIP=""
    if [ "$OS_TYPE" = "android" ]; then
        command -v termux-clipboard-get &>/dev/null && CLIP=$(termux-clipboard-get 2>/dev/null | head -1)
    else
        if command -v xclip &>/dev/null; then CLIP=$(xclip -selection clipboard -o 2>/dev/null | head -1)
        elif command -v xsel &>/dev/null; then CLIP=$(xsel --clipboard --output 2>/dev/null | head -1)
        elif command -v wl-paste &>/dev/null; then CLIP=$(wl-paste 2>/dev/null | head -1)
        fi
    fi
    CLIP="${CLIP// /}"
    [[ "$CLIP" == http* ]] && echo "$CLIP"
}

# Extract ALL URLs from clipboard (one per line)
check_clipboard_all() {
    local RAW=""
    if [ "$OS_TYPE" = "android" ]; then
        command -v termux-clipboard-get &>/dev/null && RAW=$(termux-clipboard-get 2>/dev/null)
    else
        if command -v xclip &>/dev/null; then RAW=$(xclip -selection clipboard -o 2>/dev/null)
        elif command -v xsel &>/dev/null; then RAW=$(xsel --clipboard --output 2>/dev/null)
        elif command -v wl-paste &>/dev/null; then RAW=$(wl-paste 2>/dev/null)
        fi
    fi
    # Extract every http/https URL — one per line, deduplicated
    echo "$RAW" | grep -oE 'https?://[^[:space:]"'"'"'<>]+' | sort -u
}

# ================================================================
# SPONSORBLOCK
# ================================================================
get_sponsorblock_flags() {
    local URL="$1"
    if [[ "$URL" == *"youtube.com"* || "$URL" == *"youtu.be"* ]]; then
        local SB; SB=$(get_setting sponsorblock)
        if [ "$SB" = "true" ]; then
            echo "--sponsorblock-remove sponsor,intro,outro,selfpromo,preview"
            return
        fi
    fi
    echo ""
}

# ================================================================
# THUMBNAIL PREVIEW INFO
# ================================================================
show_thumb_info() {
    local TMP_JSON="$1"
    [ -z "$TMP_JSON" ] || [ ! -f "$TMP_JSON" ] && return
    python3 -c "
import json,sys
try:
    d=json.load(open('$TMP_JSON'))
    v=d.get('view_count',0); l=d.get('like_count',0)
    t=d.get('thumbnail','')
    if v: print(f'  [38;5;244mViews  [0m[1;97m{v:,}[0m')
    if l: print(f'  [38;5;244mLikes  [0m[1;97m{l:,}[0m')
    cats=d.get('categories',[])
    if cats: print(f'  [38;5;244mCat    [0m[1;97m{", ".join(cats[:3])}[0m')
except: pass
" 2>/dev/null
}

# ================================================================
# RESUME INCOMPLETE DOWNLOAD
# ================================================================
check_resume() {
    local SAVE_PATH="$1"
    local PARTS; PARTS=$(find "$SAVE_PATH" -maxdepth 2 -name "*.part" 2>/dev/null | head -5)
    if [ -n "$PARTS" ]; then
        warn_msg "Incomplete downloads found — will resume automatically:"
        echo "$PARTS" | while read -r P; do
            local SZ; SZ=$(du -h "$P" 2>/dev/null | cut -f1)
            dim_msg "  ${SZ}  $(basename "$P")"
        done
        echo ""
    fi
}

# ================================================================
# ASCII SPEED GRAPH
# ================================================================
declare -a _SPEED_BUF=()
_SPEED_IDX=0
_SPEED_MAX_BUF=20

_speed_push() {
    local VAL="$1"
    local NUM UNIT KB=0
    # Pure bash — extract number and unit without grep -P
    [[ "$VAL" =~ ([0-9]+\.?[0-9]*)([KMG]iB) ]] && NUM="${BASH_REMATCH[1]}" && UNIT="${BASH_REMATCH[2]}"
    case "$UNIT" in
        KiB) KB="${NUM%%.*}" ;;
        MiB) KB=$(awk "BEGIN{printf \"%d\",$NUM*1024}") ;;
        GiB) KB=$(awk "BEGIN{printf \"%d\",$NUM*1048576}") ;;
        *)   KB=0 ;;
    esac
    _SPEED_BUF[$_SPEED_IDX]="${KB:-0}"
    _SPEED_IDX=$(( (_SPEED_IDX + 1) % _SPEED_MAX_BUF ))
}

_draw_speed_graph() {
    local H=4 MAX=1 i row
    for V in "${_SPEED_BUF[@]}"; do [ "${V:-0}" -gt "$MAX" ] && MAX="${V:-0}"; done
    for (( row=H; row>=1; row-- )); do
        printf "  "
        for V in "${_SPEED_BUF[@]}"; do
            local BH=$(( (${V:-0} * H) / MAX ))
            if [ "$BH" -ge "$row" ]; then
                local PCT=$(( BH * 100 / H ))
                if   [ "$PCT" -lt 40 ]; then printf "\033[38;5;196m▄\033[0m"
                elif [ "$PCT" -lt 70 ]; then printf "\033[38;5;226m▄\033[0m"
                else                         printf "\033[38;5;46m▄\033[0m"
                fi
            else
                printf "\033[38;5;238m·\033[0m"
            fi
        done
        printf "\n"
    done
}

# ================================================================
# TERMUX NOTIFICATION + TELEGRAM
# ================================================================
send_notification() {
    local TITLE="$1" MSG="$2"
    if [ "$OS_TYPE" = "android" ] && command -v termux-notification &>/dev/null; then
        termux-notification --title "ADM — Download Complete" --content "$MSG" \
            --id "adm_notify" --priority default 2>/dev/null &
    fi
    send_telegram "${TITLE}: ${MSG}"
}

send_telegram() {
    local MSG="$1"
    local TOKEN CHAT
    TOKEN=$(get_setting telegram_bot_token)
    CHAT=$(get_setting telegram_chat_id)
    [ -z "$TOKEN" ] || [ -z "$CHAT" ] && return
    curl -s --max-time 10 \
        -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
        -d "chat_id=${CHAT}" \
        --data-urlencode "text=${MSG}" \
        &>/dev/null &
}

# ── Live progress → Termux notification bar (throttled) ────────
_update_progress_notification() {
    local PCT="$1" LABEL="${2:-Downloading}"
    [ "$OS_TYPE" = "android" ] || return
    command -v termux-notification &>/dev/null || return
    termux-notification --id "adm_progress" \
        --title "ADM — ${LABEL}" \
        --content "${PCT}% complete" \
        --priority low --ongoing 2>/dev/null &
}

_clear_progress_notification() {
    [ "$OS_TYPE" = "android" ] || return
    command -v termux-notification-remove &>/dev/null && \
        termux-notification-remove "adm_progress" 2>/dev/null
}

# ================================================================
# WI-FI ONLY MODE — best-effort network type check (Termux)
# ================================================================
_on_wifi() {
    # Returns 0 if we can confirm Wi-Fi, 1 otherwise (unknown counts as "not sure")
    [ "$OS_TYPE" = "android" ] || return 0
    command -v termux-wifi-connectioninfo &>/dev/null || return 1
    local INFO STATE
    INFO=$(termux-wifi-connectioninfo 2>/dev/null)
    STATE=$(echo "$INFO" | python3 -c "import json,sys
try:
    d=json.loads(sys.stdin.read())
    print(d.get('supplicant_state','') or d.get('network_id',''))
except: print('')" 2>/dev/null)
    [ -n "$STATE" ] && [ "$STATE" != "-1" ] && [ "$STATE" != "None" ] && return 0
    return 1
}

wifi_gate_check() {
    # Returns 0 = proceed, 1 = user cancelled
    [ "$(get_setting wifi_only)" != "true" ] && return 0
    [ "$OS_TYPE" != "android" ] && return 0
    command -v termux-wifi-connectioninfo &>/dev/null || return 0
    if ! _on_wifi; then
        warn_msg "Wi-Fi Only is ON and you don't seem to be on Wi-Fi."
        echo -ne "  ${Y}Continue anyway on mobile data? [y/N]: ${N}"
        local ANS; read -r ANS
        [[ "$ANS" =~ ^[Yy]$ ]] && return 0
        info_msg "Download cancelled (Wi-Fi Only is ON)."
        return 1
    fi
    return 0
}

# ================================================================
# QR LAN TRANSFER — share the last downloaded file over local WiFi
# ================================================================
LAST_SAVED_FILE=""

share_file_qr() {
    local F="${1:-$LAST_SAVED_FILE}"
    if [ -z "$F" ] || [ ! -f "$F" ]; then
        error_msg "No downloaded file to share yet."
        sleep 2; return
    fi
    local IP
    IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
    [ -z "$IP" ] && IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [ -z "$IP" ]; then
        error_msg "Could not detect local IP. Are you on Wi-Fi?"
        sleep 2; return
    fi

    local DIR BASENAME PORT=8181
    DIR="$(dirname "$F")"
    BASENAME="$(basename "$F")"
    local URL="http://${IP}:${PORT}/$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$BASENAME" 2>/dev/null)"

    clear 2>/dev/null
    echo -e "  ${BOLD}${C}SHARE OVER WI-FI${N}"
    line "-"
    echo -e "  ${W}File:${N} ${BASENAME}"
    echo -e "  ${W}URL: ${N} ${G}${URL}${N}"
    echo ""
    if ! command -v qrencode &>/dev/null; then
        info_msg "Installing qrencode (one-time)..."
        auto_install qrencode
    fi
    if command -v qrencode &>/dev/null; then
        qrencode -t ANSIUTF8 "$URL"
    else
        warn_msg "qrencode not available — showing link only. Type it in the other device's browser."
    fi
    echo ""
    echo -e "  ${DIM}Both devices must be on the same Wi-Fi. Press Enter to stop sharing.${N}"

    ( cd "$DIR" && python3 -m http.server "$PORT" --bind 0.0.0.0 &>/dev/null ) &
    local _SRV_PID=$!
    read -r
    kill "$_SRV_PID" 2>/dev/null
}

# ================================================================
# PASSWORD PROTECTED VIDEO
# ================================================================
ask_video_password() {
    echo ""
    warn_msg "This video may be password protected."
    echo -ne "  \033[1;37mVideo password\033[0m (Enter=skip): "
    read -r VID_PASS
    echo "${VID_PASS:-}"
}

# ================================================================
# SUBTITLE LANGUAGE
# ================================================================
get_subtitle_flags() {
    local FLAGS_OUT=()
    if [ "$(get_setting save_subtitle)" = "true" ]; then
        local LANG; LANG=$(get_setting subtitle_lang)
        [ -z "$LANG" ] && LANG="en"
        FLAGS_OUT+=(--write-auto-sub --write-sub --sub-langs "$LANG" --convert-subs srt)
    fi
    echo "${FLAGS_OUT[@]}"
}

set_subtitle_lang() {
    echo ""
    info_msg "Language codes: en bn hi ar fr de es ja zh"
    echo -ne "  \033[1;97mSubtitle language\033[0m (default=en): "
    read -r LC
    [ -z "$LC" ] && LC="en"
    set_setting subtitle_lang "$LC"
    success_msg "Subtitle language: ${LC}"
    sleep 1
}


# ================================================================
# TMUX — Linux only
# ================================================================
launch_in_tmux() {
    [ "$OS_TYPE" = "android" ] && return 1
    command -v tmux &>/dev/null || auto_install tmux
    command -v tmux &>/dev/null || return 1

    if [ -n "$TMUX" ]; then
        [ "$(tmux display-message -p '#S' 2>/dev/null)" = "$TMUX_SESSION" ] && return 0
    fi

    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null
    local W H
    W=$(tput cols  2>/dev/null || echo 200)
    H=$(tput lines 2>/dev/null || echo 50)

    tmux new-session -d -s "$TMUX_SESSION" -x "$W" -y "$H"
    tmux set-option -t "$TMUX_SESSION" status off
    tmux set-option -t "$TMUX_SESSION" pane-border-style        "fg=colour236"
    tmux set-option -t "$TMUX_SESSION" pane-active-border-style "fg=colour236"
    tmux split-window -v -t "$TMUX_SESSION" -l "$HEADER_LINES" -b
    tmux select-pane -t "$TMUX_SESSION:0.0"
    tmux set-option -t "$TMUX_SESSION:0.0" remain-on-exit on
    tmux send-keys -t "$TMUX_SESSION:0.0" "bash '$SCRIPT_PATH' --header-loop" Enter
    tmux select-pane -t "$TMUX_SESSION:0.1"
    tmux send-keys -t "$TMUX_SESSION:0.1" "bash '$SCRIPT_PATH' --main" Enter
    tmux select-pane -t "$TMUX_SESSION:0.1"
    tmux attach-session -t "$TMUX_SESSION"
    exit 0
}

# ================================================================
# UI HELPERS
# ================================================================
get_width() { tput cols 2>/dev/null || echo 80; }

# Pure bash repeat — no seq, no subshell
_repeat_char() {
    local char="$1" count="$2" i
    for (( i=0; i<count; i++ )); do printf "%s" "$char"; done
}

separator() {
    local char="${1:-=}" color="${2:-$C}"
    local w; w=$(get_width)
    printf "${color}"; _repeat_char "$char" "$w"; printf "${N}\n"
}

line() {
    local char="${1:--}" color="${2:-$DIM$C}"
    local w; w=$(get_width)
    printf "${color}"; _repeat_char "$char" "$w"; printf "${N}\n"
}

center_text() {
    local text="$1" color="${2:-$W}"
    local w; w=$(get_width)
    local len=${#text}
    local pad=$(( (w - len) / 2 ))
    [ $pad -lt 0 ] && pad=0
    printf "${color}%${pad}s%s${N}\n" "" "$text"
}

# ── Bengali UI (opt-in: cfg > Language). Unknown strings stay English. ──
t() {
    [ "$(get_setting language)" != "bn" ] && { printf '%s' "$1"; return; }
    case "$1" in
        "Invalid choice")            printf '%s' "ভুল অপশন" ;;
        "Invalid number")            printf '%s' "ভুল নম্বর" ;;
        "Invalid name")              printf '%s' "ভুল নাম" ;;
        "No results found.")         printf '%s' "কোনো ফলাফল পাওয়া যায়নি।" ;;
        "Searching...")              printf '%s' "খোঁজা হচ্ছে..." ;;
        "Cancelled.")                printf '%s' "বাতিল করা হয়েছে।" ;;
        "Download cancelled (Wi-Fi Only is ON).") printf '%s' "ডাউনলোড বাতিল (শুধু Wi-Fi মোড চালু)।" ;;
        "Wrong passphrase.")         printf '%s' "ভুল পাসফ্রেজ।" ;;
        "Cookie unlocked.")          printf '%s' "কুকি আনলক হয়েছে।" ;;
        "Wi-Fi Only: ON"*)           printf '%s' "শুধু Wi-Fi মোড: চালু" ;;
        "Wi-Fi Only: OFF")           printf '%s' "শুধু Wi-Fi মোড: বন্ধ" ;;
        "Data Saver: ON"*)           printf '%s' "ডেটা সেভার: চালু (সর্বোচ্চ 480p)" ;;
        "Data Saver: OFF")           printf '%s' "ডেটা সেভার: বন্ধ" ;;
        "Auto Compress: OFF")        printf '%s' "অটো কম্প্রেস: বন্ধ" ;;
        "Auto Compress: ON"*)        printf '%s' "অটো কম্প্রেস: চালু" ;;
        "No downloaded file to share yet.") printf '%s' "শেয়ার করার মতো কোনো ডাউনলোড নেই।" ;;
        "Download failed. Updating yt-dlp and retrying...") printf '%s' "ডাউনলোড ব্যর্থ। yt-dlp আপডেট করে আবার চেষ্টা হচ্ছে..." ;;
        "All retried downloads succeeded!") printf '%s' "রিট্রাই করা সব ডাউনলোড সফল!" ;;
        "Best Quality")              printf '%s' "সেরা কোয়ালিটি" ;;
        "Audio MP3")                 printf '%s' "অডিও MP3" ;;
        "Resolution")                printf '%s' "রেজোলিউশন" ;;
        *)                           printf '%s' "$1" ;;
    esac
}
success_msg() { echo -e "${G}  [+] $(t "$1")${N}"; }
error_msg()   { echo -e "${R}  [!] $(t "$1")${N}"; }
warn_msg()    { echo -e "${Y}  [~] $(t "$1")${N}"; }
info_msg()    { echo -e "${C}  [*] $(t "$1")${N}"; }
dim_msg()     { echo -e "${DIM}      $1${N}"; }

# ================================================================
# BANNER
# ================================================================
draw_banner() {
    local w; w=$(get_width)
    local DT DT_S OS_LABEL
    DT=$(date '+%d %b %Y  |  %I:%M %p')
    DT_S=$(date '+%d %b %y | %I:%M %p')
    [ "$OS_TYPE" = "android" ] && OS_LABEL="Android (Termux)" || OS_LABEL="Linux"
    clear 2>/dev/null || tput clear 2>/dev/null

    if [ "$w" -ge 72 ]; then
        # ── Wide terminal / landscape ──
        local bw=72
        local pad=$(( (w - bw) / 2 ))
        [ $pad -lt 0 ] && pad=0
        local SP; SP=$(printf "%${pad}s" "")
        echo -e "\033[38;5;33m"
        echo "${SP}  ░█████╗░██████╗░███╗░░░███╗"
        echo "${SP}  ██╔══██╗██╔══██╗████╗░████║"
        echo "${SP}  ███████║██║░░██║██╔████╔██║"
        echo "${SP}  ██╔══██║██║░░██║██║╚██╔╝██║"
        echo "${SP}  ██║░░██║██████╔╝██║░╚═╝░██║"
        echo "${SP}  ╚═╝░░╚═╝╚═════╝░╚═╝░░░░╚═╝"
        echo -e "\033[0m"
        printf "\033[38;5;244m%${w}s\033[0m\n" "A. Professor's Download Manager  "
        printf "\033[38;5;91m%${w}s\033[0m\n" "𝕬𝖋𝖓𝖆𝖓 𝕾𝖆𝖒𝖎𝖗  "
        echo -e "${N}"
    else
        # ── Phone / narrow terminal: same ADM logo, centred, compact lines ──
        if [ "$w" -ge 29 ]; then
            local apad=$(( (w - 27) / 2 )) ASP AL
            ASP=$(printf "%${apad}s" "")
            printf "\033[38;5;33m"
            for AL in "░█████╗░██████╗░███╗░░░███╗" \
                      "██╔══██╗██╔══██╗████╗░████║" \
                      "███████║██║░░██║██╔████╔██║" \
                      "██╔══██║██║░░██║██║╚██╔╝██║" \
                      "██║░░██║██████╔╝██║░╚═╝░██║" \
                      "╚═╝░░╚═╝╚═════╝░╚═╝░░░░╚═╝"; do
                printf "%s%s\n" "$ASP" "$AL"
            done
            printf "\033[0m"
        else
            center_text "A  D  M" "${BOLD}\033[38;5;33m"
        fi
        if [ "$w" -ge 34 ]; then
            center_text "A. Professor's Download Manager" "${BOLD}\033[38;5;244m"
        else
            center_text "A. Professor's" "${BOLD}\033[38;5;244m"
            center_text "Download Manager" "${BOLD}\033[38;5;244m"
        fi
        center_text "Afnan Samir" "\033[38;5;91m"
    fi

    separator "="
    if   [ "$w" -ge 72 ]; then
        center_text "Version : ${VERSION}   |   ${DT}   |   ${OS_LABEL}" "${DIM}${W}"
    elif [ "$w" -ge 56 ]; then
        center_text "${VERSION}  |  ${DT}  |  ${OS_LABEL}" "${DIM}${W}"
    elif [ "$w" -ge 31 ]; then
        center_text "${VERSION} | ${DT_S}" "${DIM}${W}"
    else
        center_text "${VERSION}" "${DIM}${W}"
    fi
    separator "="
    line "-"
    if   [ "$w" -ge 72 ]; then
        center_text "link=download  play=player  st=stats  hist=history  cfg=settings  q=quit" "${Y}"
    elif [ "$w" -ge 38 ]; then
        center_text "link=download  play=player  st=stats" "${Y}"
        center_text "hist=history  cfg=settings  q=quit" "${Y}"
    else
        center_text "link=download  play=player" "${Y}"
        center_text "st=stats  hist=history" "${Y}"
        center_text "cfg=settings  q=quit" "${Y}"
    fi
    line "-"
    echo ""
}

header_loop() {
    export TERM="${TERM:-xterm-256color}"
    tput civis 2>/dev/null
    while true; do
        draw_banner
        sleep 55
    done
}

# ================================================================
# VPN DETECT
# ================================================================
check_vpn() {
    if ip link show 2>/dev/null | grep -qE "tun[0-9]|tap[0-9]|wg[0-9]|ppp[0-9]"; then
        echo "on"; return
    fi
    if ifconfig 2>/dev/null | grep -qE "tun[0-9]|tap[0-9]"; then
        echo "on"; return
    fi
    echo "off"
}

suggest_vpn_if_needed() {
    local VPN_STATUS; VPN_STATUS=$(check_vpn)
    if [ "$VPN_STATUS" = "off" ]; then
        echo ""
        warn_msg "VPN is not active."
        dim_msg  "If download keeps failing, try enabling a VPN and retry."
    fi
}

# ================================================================
# PLATFORM COOKIE MESSAGE
# ================================================================
cookie_hint() {
    local PLATFORM="$1"
    case "$PLATFORM" in
        YouTube)   warn_msg "YouTube login required. Add YouTube cookie: cfg > 6" ;;
        Facebook)  warn_msg "Facebook login required. Add Facebook cookie: cfg > 6" ;;
        Instagram) warn_msg "Instagram login required. Add Instagram cookie: cfg > 6" ;;
        Pinterest) warn_msg "Pinterest login required. Add Pinterest cookie: cfg > 6" ;;
        Twitter)   warn_msg "Twitter login may be required. Add cookie: cfg > 6" ;;
        *)         warn_msg "Login may be required. Add cookie: cfg > 6" ;;
    esac
}

# ================================================================
# STATS
# ================================================================
update_stats() {
    local ELAPSED="${1:-0}"
    python3 - "$STATS_FILE" "$ELAPSED" << 'PYEOF' 2>/dev/null
import json, sys
f = sys.argv[1]; t = int(sys.argv[2])
try:    d = json.load(open(f))
except: d = {'total_downloads': 0, 'total_time': 0}
d['total_downloads'] = d.get('total_downloads', 0) + 1
d['total_time']      = d.get('total_time', 0) + t
json.dump(d, open(f, 'w'))
PYEOF
}

update_stats() {
    local ELAPSED="${1:-0}"
    python3 - "$STATS_FILE" "$ELAPSED" << 'PYEOF' 2>/dev/null
import json, sys
f = sys.argv[1]; t = int(sys.argv[2])
try:    d = json.load(open(f))
except: d = {'total_downloads': 0, 'total_time': 0}
d['total_downloads'] = d.get('total_downloads', 0) + 1
d['total_time']      = d.get('total_time', 0) + t
json.dump(d, open(f, 'w'))
PYEOF
}

# ================================================================
# DOWNLOAD HISTORY
# ================================================================
history_add() {
    local URL="$1" TITLE="$2" PLATFORM="$3" QUALITY="$4" FNAME="$5"
    python3 - "$HISTORY_FILE" "$URL" "$TITLE" "$PLATFORM" "$QUALITY" "$FNAME" << 'PYEOF' 2>/dev/null
import json, sys
from datetime import datetime
f, url, title, platform, quality, fname = sys.argv[1:]
try:    h = json.load(open(f))
except: h = []
h.insert(0, {
    "url": url, "title": title, "platform": platform,
    "quality": quality, "file": fname,
    "date": datetime.now().strftime("%Y-%m-%d %H:%M")
})
h = h[:200]  # keep last 200
json.dump(h, open(f, 'w'), indent=2, ensure_ascii=False)
PYEOF
}

history_check_duplicate() {
    local URL="$1"
    python3 - "$HISTORY_FILE" "$URL" << 'PYEOF' 2>/dev/null
import json, sys
f, url = sys.argv[1], sys.argv[2]
try:    h = json.load(open(f))
except: h = []
match = next((e for e in h if e.get('url') == url), None)
if match:
    print(f"{match.get('date','?')}|{match.get('title','?')[:50]}")
PYEOF
}

show_history() {
    separator "="
    center_text "DOWNLOAD HISTORY" "${BOLD}${C}"
    line "-"
    python3 - "$HISTORY_FILE" << 'PYEOF' 2>/dev/null
import json, sys
try:    h = json.load(open(sys.argv[1]))
except: h = []
if not h:
    print("  No downloads yet.")
else:
    for i, e in enumerate(h[:30], 1):
        print(f"  {i:>2}. [{e.get('date','?')}] {e.get('platform','?')} · {e.get('quality','?')}")
        print(f"      {e.get('title','?')[:60]}")
        print()
PYEOF
    line "-"
    echo -ne "  ${DIM}Press Enter to continue...${N}"; read -r
}

# ================================================================
# YT-DLP VERSION CHECK
# ================================================================
ytdlp_version_check() {
    local CURRENT LATEST
    CURRENT=$(yt-dlp --version 2>/dev/null)
    LATEST=$(pip3 index versions yt-dlp 2>/dev/null | grep -o '[0-9][0-9][0-9][0-9]\.[0-9][0-9]\.[0-9][0-9]' | head -1)
    [ -z "$LATEST" ] && return
    if [ -n "$CURRENT" ] && [ -n "$LATEST" ] && [ "$CURRENT" != "$LATEST" ]; then
        warn_msg "yt-dlp update available: ${CURRENT} → ${LATEST}  (cfg > Update)"
        sleep 2
    fi
}

show_stats() {
    separator "="
    center_text "STATISTICS" "${BOLD}${C}"
    line "-"
    python3 - "$STATS_FILE" << 'PYEOF' 2>/dev/null
import json, sys
f = sys.argv[1]
try:    d = json.load(open(f))
except: d = {'total_downloads': 0, 'total_time': 0}
t = int(d.get('total_time', 0)); h, r = divmod(t, 3600); m, s = divmod(r, 60)
print(f"  Total Downloads : {d.get('total_downloads', 0)}")
print(f"  Total Time      : {h}h {m}m {s}s")
PYEOF
    separator "="
    echo -ne "  ${DIM}Press Enter to continue...${N}"; read -r
}

# ================================================================
# EVENT / ERROR LOG VIEWER
# ================================================================
show_log() {
    separator "="
    center_text "ERROR / EVENT LOG" "${BOLD}${C}"
    line "-"
    if [ -s "$LOG_FILE" ]; then
        tail -n 40 "$LOG_FILE" | while IFS= read -r LN; do
            case "$LN" in
                *"ERROR"*) echo -e "  ${R}${LN}${N}" ;;
                *"WARN"*)  echo -e "  ${Y}${LN}${N}" ;;
                *)         echo -e "  ${DIM}${LN}${N}" ;;
            esac
        done
    else
        echo -e "  ${DIM}Log is empty — no errors recorded yet.${N}"
    fi
    line "-"
    echo -e "  ${DIM}Full log file: ${LOG_FILE}${N}"
    echo -ne "  ${DIM}Press Enter to continue...${N}"; read -r
}

# ================================================================
# ANDROID MEDIA SCANNER
# FIX: Use am broadcast (no Termux:API needed) + termux-media-scan
#      as fallback. Scans the exact FILE, not just the folder.
# ================================================================
trigger_media_scan() {
    local TARGET="$1"
    [ "$OS_TYPE" != "android" ] && return
    [ -z "$TARGET" ]           && return

    # Method 1: Android built-in broadcast — no extra app needed
    if command -v am &>/dev/null; then
        am broadcast \
            -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
            -d "file://${TARGET}" \
            --user 0 \
            > /dev/null 2>&1 || true
    fi

    # Method 2: termux-media-scan on the exact file (needs Termux:API)
    if command -v termux-media-scan &>/dev/null; then
        termux-media-scan "$TARGET" > /dev/null 2>&1 || true
    fi
}

# ================================================================
# COOKIE MANAGER
# ================================================================
# ================================================================
# APP LOCK — PIN required at launch (stored as salted SHA-256 only)
# ================================================================
_pin_hash() { printf '%s' "adm-pin:$1" | sha256sum | cut -d' ' -f1; }

check_app_lock() {
    local H; H=$(get_setting app_pin_hash)
    [ -z "$H" ] && return 0
    local tries=0 P
    while [ "$tries" -lt 3 ]; do
        echo -ne "  ${W}Enter PIN${N}: "; read -rs P; echo
        [ "$(_pin_hash "$P")" = "$H" ] && return 0
        tries=$(( tries + 1 ))
        error_msg "Wrong PIN (${tries}/3)"
    done
    log_msg "WARN" "App lock: 3 wrong PIN attempts"
    exit 1
}

set_app_pin() {
    local H; H=$(get_setting app_pin_hash)
    if [ -n "$H" ]; then
        echo -ne "  ${W}Current PIN${N}: "; local C0; read -rs C0; echo
        [ "$(_pin_hash "$C0")" = "$H" ] || { error_msg "Wrong PIN"; sleep 2; return; }
    fi
    echo -ne "  ${W}New PIN${N} (4+ digits, Enter=remove lock): "; local P1; read -rs P1; echo
    if [ -z "$P1" ]; then
        set_setting app_pin_hash ""
        success_msg "App lock removed"; sleep 1; return
    fi
    if ! [[ "$P1" =~ ^[0-9]{4,12}$ ]]; then
        error_msg "PIN must be 4-12 digits"; sleep 2; return
    fi
    echo -ne "  ${W}Repeat PIN${N}: "; local P2; read -rs P2; echo
    [ "$P1" = "$P2" ] || { error_msg "PINs don't match"; sleep 2; return; }
    set_setting app_pin_hash "$(_pin_hash "$P1")"
    success_msg "App lock enabled"
    log_msg "INFO" "App lock enabled"
    sleep 1
}

# ================================================================
# BACKUP / RESTORE — settings, history, cookies in one .tar.gz
# ================================================================
_backup_dir() {
    if [ "$OS_TYPE" = "android" ] && [ -d /sdcard/Download ]; then echo "/sdcard/Download"
    else echo "$HOME"; fi
}

backup_settings() {
    local OUT; OUT="$(_backup_dir)/adm_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
    if tar -czf "$OUT" -C "$DATA_DIR" . 2>/dev/null; then
        chmod 600 "$OUT" 2>/dev/null
        success_msg "Backup saved: ${OUT}"
        warn_msg "It contains your cookies — keep it private."
        log_msg "INFO" "Backup created: ${OUT}"
    else
        error_msg "Backup failed."
    fi
}

restore_settings() {
    echo -ne "  ${W}Path to backup .tar.gz${N}: "
    local F; read -r F
    if [ ! -f "$F" ] || ! tar -tzf "$F" &>/dev/null; then
        error_msg "Not a valid backup file."; return 1
    fi
    echo -ne "  ${R}This overwrites current settings/history/cookies. Type YES: ${N}"
    local C0; read -r C0
    [ "$C0" = "YES" ] || { info_msg "Cancelled."; return 1; }
    if tar -xzf "$F" -C "$DATA_DIR" 2>/dev/null; then
        _cfg_load
        success_msg "Restore complete."
        log_msg "INFO" "Restored backup: ${F}"
    else
        error_msg "Restore failed."
    fi
}

# ================================================================
# DOWNLOAD SCHEDULER — run a link list at a chosen time
# ================================================================
run_file_batch() {
    # Non-interactive: used by the scheduler (adm --run-file FILE CHOICE)
    local F="$1" CH="${2:-5}"
    [ -f "$F" ] || { log_msg "ERROR" "Scheduled file missing: $F"; return 1; }
    local -a LNS=()
    local LN
    while IFS= read -r LN || [ -n "$LN" ]; do
        LN="$(echo "$LN" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -z "$LN" ] && continue
        [[ "$LN" == \#* ]] && continue
        LNS+=("$LN")
    done < "$F"
    [ ${#LNS[@]} -eq 0 ] && return 0
    log_msg "INFO" "Scheduled batch started: ${#LNS[@]} links from ${F}"
    SUCCESS=0; FAIL_LIST=()
    run_parallel_batch "$CH" "${LNS[@]}"
    if [ $? -eq 2 ]; then
        local i
        for i in "${!LNS[@]}"; do
            do_download "${LNS[$i]}" "$CH" "$(( i + 1 ))" "${#LNS[@]}" < /dev/null
            if [ $? -eq 0 ]; then SUCCESS=$(( SUCCESS + 1 )); else FAIL_LIST+=("${LNS[$i]}"); fi
        done
    fi
    send_telegram "Scheduled batch finished: ${SUCCESS}/${#LNS[@]} succeeded"
    log_msg "INFO" "Scheduled batch done: ${SUCCESS}/${#LNS[@]}"
}

schedule_downloads() {
    clear 2>/dev/null
    separator "="
    center_text "SCHEDULE DOWNLOADS" "${BOLD}${C}"
    separator "="
    echo ""
    echo -ne "  ${W}Links file${N} (.txt, one link per line): "
    local F; read -r F
    [ -f "$F" ] || { error_msg "File not found."; sleep 2; return; }
    echo -ne "  ${W}Start time${N} (HH:MM, 24h): "
    local HM; read -r HM
    [[ "$HM" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]] || { error_msg "Use HH:MM (e.g. 02:30)"; sleep 2; return; }
    show_menu_simple
    echo -ne "  ${W}Quality${N} (1-7): "
    local CH; read -r CH
    [[ "$CH" =~ ^[1-7]$ ]] || { error_msg "Invalid choice"; sleep 1; return; }

    local NOW TGT SECS
    NOW=$(date +%s); TGT=$(date -d "$HM" +%s 2>/dev/null)
    [ -z "$TGT" ] && { error_msg "Could not parse time."; sleep 2; return; }
    [ "$TGT" -le "$NOW" ] && TGT=$(( TGT + 86400 ))
    SECS=$(( TGT - NOW ))

    local ABS_F; ABS_F="$(cd "$(dirname "$F")" && pwd)/$(basename "$F")"
    local INST; INST="$(_adm_bin_dir)/adm"; [ -x "$INST" ] || INST="$SCRIPT_PATH"
    local WL=""; command -v termux-wake-lock &>/dev/null && WL="termux-wake-lock;"
    nohup bash -c "${WL} sleep ${SECS}; bash '${INST}' --run-file '${ABS_F}' ${CH}" \
        &>/dev/null &
    disown 2>/dev/null
    success_msg "Scheduled for $(date -d "@${TGT}" '+%a %d %b %H:%M') (in $(( SECS / 3600 ))h $(( SECS % 3600 / 60 ))m)"
    warn_msg "Keep Termux alive: disable battery optimization for Termux."
    log_msg "INFO" "Scheduled ${ABS_F} at $(date -d "@${TGT}" '+%F %H:%M') quality ${CH}"
    echo -ne "  ${DIM}Press Enter to continue...${N}"; read -r
}

# ================================================================
# CHANNEL / PLAYLIST SYNC — download only NEW videos since last check
# ================================================================
SUBS_FILE="$DATA_DIR/subs.txt"

sub_add() {
    echo -ne "  ${W}Channel/playlist URL${N}: "
    local U; read -r U
    [ -z "$U" ] && return
    info_msg "Reading latest video..."
    local NEWEST
    NEWEST=$(yt-dlp --flat-playlist --playlist-items 1 --print id "$U" 2>/dev/null | head -n1)
    if [ -z "$NEWEST" ]; then
        error_msg "Could not read that URL."; sleep 2; return
    fi
    grep -qF "${U}|" "$SUBS_FILE" 2>/dev/null && { warn_msg "Already subscribed."; sleep 1; return; }
    echo "${U}|${NEWEST}" >> "$SUBS_FILE"
    success_msg "Subscribed. Only videos newer than now will be downloaded."
    log_msg "INFO" "Subscribed: ${U}"
    sleep 2
}

sub_sync() {
    [ -s "$SUBS_FILE" ] || { info_msg "No subscriptions yet."; return 0; }
    local Q; Q=$(get_setting sync_quality); [[ "$Q" =~ ^[1-7]$ ]] || Q=5
    local TMPS; TMPS="$(mktemp "${TMP_DIR}/adm_subs_XXXXXX")"
    local U LAST ID TOTAL_NEW=0
    while IFS='|' read -r U LAST; do
        [ -z "$U" ] && continue
        local -a IDS=() NEW=()
        mapfile -t IDS < <(yt-dlp --flat-playlist --playlist-items 1:15 --print id "$U" 2>/dev/null)
        if [ ${#IDS[@]} -eq 0 ]; then echo "${U}|${LAST}" >> "$TMPS"; continue; fi
        for ID in "${IDS[@]}"; do
            [ "$ID" = "$LAST" ] && break
            NEW+=("$ID")
        done
        if [ ${#NEW[@]} -gt 0 ]; then
            info_msg "${#NEW[@]} new video(s) in ${U}"
            local k
            for (( k=${#NEW[@]}-1; k>=0; k-- )); do
                do_download "https://www.youtube.com/watch?v=${NEW[$k]}" "$Q" 1 1 < /dev/null
            done
            TOTAL_NEW=$(( TOTAL_NEW + ${#NEW[@]} ))
            echo "${U}|${IDS[0]}" >> "$TMPS"
        else
            echo "${U}|${LAST}" >> "$TMPS"
        fi
    done < "$SUBS_FILE"
    mv -f "$TMPS" "$SUBS_FILE"
    log_msg "INFO" "Sync finished: ${TOTAL_NEW} new video(s)"
    [ "$TOTAL_NEW" -gt 0 ] && send_telegram "Sync: ${TOTAL_NEW} new video(s) downloaded"
    success_msg "Sync complete: ${TOTAL_NEW} new video(s)."
}

subscriptions_menu() {
    while true; do
        clear 2>/dev/null
        separator "="
        center_text "CHANNEL / PLAYLIST SYNC" "${BOLD}${C}"
        separator "="
        echo ""
        if [ -s "$SUBS_FILE" ]; then
            local n=0 U L
            while IFS='|' read -r U L; do
                n=$(( n + 1 )); echo -e "  ${W}${n}${N}  ${U:0:60}"
            done < "$SUBS_FILE"
        else
            echo -e "  ${DIM}No subscriptions yet.${N}"
        fi
        echo ""
        separator "-"
        echo -e "  ${C}a${N} Add    ${C}r${N} Remove    ${C}s${N} Sync now    ${C}q${N} Quality (now: $(get_setting sync_quality))"
        echo -e "  ${DIM}Tip: run 'adm sync' from Termux:Boot / cron for automatic checks.${N}"
        separator "-"
        echo -ne "  ${Y}Select (Enter=back): ${N}"
        local A; read -r A
        case "$A" in
            "") return ;;
            a|A) sub_add ;;
            r|R)
                echo -ne "  ${W}Number to remove${N}: "; local R0; read -r R0
                if [[ "$R0" =~ ^[0-9]+$ ]] && [ -s "$SUBS_FILE" ]; then
                    sed -i "${R0}d" "$SUBS_FILE" 2>/dev/null && success_msg "Removed."
                else error_msg "Invalid number"; fi
                sleep 1 ;;
            s|S) sub_sync; echo -ne "  ${DIM}Press Enter...${N}"; read -r ;;
            q|Q)
                show_menu_simple
                echo -ne "  ${W}Sync quality${N} (1-7): "; local QQ; read -r QQ
                [[ "$QQ" =~ ^[1-7]$ ]] && set_setting sync_quality "$QQ" && success_msg "Saved." || error_msg "Invalid choice"
                sleep 1 ;;
        esac
    done
}

# ================================================================
# COOKIE PROFILES — save / switch between multiple accounts
# ================================================================
cookie_profiles_menu() {
    while true; do
        clear 2>/dev/null
        separator "="
        center_text "COOKIE PROFILES" "${BOLD}${C}"
        separator "="
        echo ""
        local -a PROFS=()
        local f
        for f in "$DATA_DIR"/cookies_*.txt; do
            [ -f "$f" ] || continue
            PROFS+=("$(basename "$f" .txt | sed 's/^cookies_//')")
        done
        if [ ${#PROFS[@]} -eq 0 ]; then
            echo -e "  ${DIM}No saved profiles yet.${N}"
        else
            local i
            for i in "${!PROFS[@]}"; do
                echo -e "  ${W}$(( i + 1 ))${N}  ${PROFS[$i]}"
            done
        fi
        echo ""
        separator "-"
        echo -e "  ${C}s${N}  Save current cookie as new profile"
        echo -e "  ${C}d${N}  Delete a profile"
        echo -e "  ${DIM}Type a number to switch to that profile${N}"
        separator "-"
        echo -ne "  ${Y}Select (Enter=back): ${N}"
        local A; read -r A
        case "$A" in
            "") return ;;
            s|S)
                if [ ! -s "$COOKIE_FILE" ]; then
                    error_msg "No active cookie to save."; sleep 2; continue
                fi
                echo -ne "  ${W}Profile name${N} (letters/numbers): "
                local NM; read -r NM
                NM=$(echo "$NM" | tr -cd 'A-Za-z0-9_-')
                [ -z "$NM" ] && { error_msg "Invalid name"; sleep 1; continue; }
                cp -f "$COOKIE_FILE" "$DATA_DIR/cookies_${NM}.txt"
                chmod 600 "$DATA_DIR/cookies_${NM}.txt" 2>/dev/null
                success_msg "Saved profile: ${NM}"
                log_msg "INFO" "Cookie profile saved: ${NM}"
                sleep 1 ;;
            d|D)
                echo -ne "  ${W}Number to delete${N}: "
                local D; read -r D
                if [[ "$D" =~ ^[0-9]+$ ]] && [ "$D" -ge 1 ] && [ "$D" -le "${#PROFS[@]}" ]; then
                    rm -f "$DATA_DIR/cookies_${PROFS[$((D-1))]}.txt"
                    success_msg "Deleted: ${PROFS[$((D-1))]}"
                else
                    error_msg "Invalid number"
                fi
                sleep 1 ;;
            *)
                if [[ "$A" =~ ^[0-9]+$ ]] && [ "$A" -ge 1 ] && [ "$A" -le "${#PROFS[@]}" ]; then
                    cp -f "$DATA_DIR/cookies_${PROFS[$((A-1))]}.txt" "$COOKIE_FILE"
                    chmod 600 "$COOKIE_FILE" 2>/dev/null
                    success_msg "Active cookie: ${PROFS[$((A-1))]}"
                    log_msg "INFO" "Cookie profile activated: ${PROFS[$((A-1))]}"
                    sleep 1
                else
                    error_msg "Invalid choice"; sleep 1
                fi ;;
        esac
    done
}

# ================================================================
# COOKIE LOCK — encrypt/decrypt the active cookie (AES-256, openssl)
# ================================================================
cookie_lock_menu() {
    local ENC="${COOKIE_FILE}.enc"
    if ! command -v openssl &>/dev/null; then
        info_msg "Installing openssl (one-time)..."
        if [ "$OS_TYPE" = "android" ]; then pkg install openssl-tool -y -q 2>/dev/null
        else sudo apt install openssl -y -q 2>/dev/null; fi
    fi
    command -v openssl &>/dev/null || { error_msg "openssl not available."; sleep 2; return; }

    clear 2>/dev/null
    separator "="
    center_text "COOKIE LOCK" "${BOLD}${C}"
    separator "="
    echo ""
    if [ -s "$COOKIE_FILE" ]; then
        echo -e "  ${G}Cookie is UNLOCKED${N} ${DIM}(plain text on disk)${N}"
        echo -e "  ${W}l${N}  Lock it (encrypt + remove plain file)"
    elif [ -s "$ENC" ]; then
        echo -e "  ${Y}Cookie is LOCKED${N} ${DIM}(encrypted)${N}"
        echo -e "  ${W}u${N}  Unlock it (needs passphrase)"
    else
        echo -e "  ${DIM}No cookie to lock. Import one first.${N}"
        sleep 2; return
    fi
    echo ""
    echo -ne "  ${Y}Select (Enter=back): ${N}"
    local A; read -r A
    case "$A" in
        l|L)
            [ -s "$COOKIE_FILE" ] || return
            echo -ne "  ${W}Set passphrase${N}: "; local P1; read -rs P1; echo
            echo -ne "  ${W}Repeat passphrase${N}: "; local P2; read -rs P2; echo
            if [ -z "$P1" ] || [ "$P1" != "$P2" ]; then
                error_msg "Passphrases empty or don't match."; sleep 2; return
            fi
            if openssl enc -aes-256-cbc -pbkdf2 -salt -in "$COOKIE_FILE" -out "$ENC" -pass "pass:${P1}" 2>/dev/null; then
                rm -f "$COOKIE_FILE"
                chmod 600 "$ENC" 2>/dev/null
                success_msg "Cookie locked. Unlock it before downloading login-only content."
                log_msg "INFO" "Cookie locked"
            else
                rm -f "$ENC"; error_msg "Encryption failed."
            fi
            sleep 2 ;;
        u|U)
            [ -s "$ENC" ] || return
            echo -ne "  ${W}Passphrase${N}: "; local P; read -rs P; echo
            if openssl enc -d -aes-256-cbc -pbkdf2 -in "$ENC" -out "$COOKIE_FILE" -pass "pass:${P}" 2>/dev/null \
               && grep -q "^[^#]" "$COOKIE_FILE" 2>/dev/null; then
                chmod 600 "$COOKIE_FILE" 2>/dev/null
                rm -f "$ENC"
                success_msg "Cookie unlocked."
                log_msg "INFO" "Cookie unlocked"
            else
                rm -f "$COOKIE_FILE"; error_msg "Wrong passphrase."
            fi
            sleep 2 ;;
    esac
}

cookie_manager() {
    while true; do
        clear 2>/dev/null
        separator "="
        center_text "COOKIE MANAGER" "${BOLD}${C}"
        separator "="
        echo ""

        if [ -s "$COOKIE_FILE" ]; then
            local CK_SIZE CK_DATE CK_LINES
            CK_SIZE=$(du -h "$COOKIE_FILE" 2>/dev/null | cut -f1)
            CK_DATE=$(date -r "$COOKIE_FILE" '+%d %b %Y  %I:%M %p' 2>/dev/null || \
                      stat -c '%y' "$COOKIE_FILE" 2>/dev/null | cut -d'.' -f1)
            CK_LINES=$(grep -c "^[^#]" "$COOKIE_FILE" 2>/dev/null || echo 0)
            echo -e "  ${G}  Cookie Status  :  ACTIVE${N}"
            echo -e "  ${DIM}  Entries        :  ${CK_LINES} domains${N}"
            echo -e "  ${DIM}  File Size      :  ${CK_SIZE}${N}"
            echo -e "  ${DIM}  Last Updated   :  ${CK_DATE}${N}"
        else
            echo -e "  ${R}  Cookie Status  :  NOT SET${N}"
            echo -e "  ${DIM}  No cookie file found.${N}"
        fi

        echo ""
        separator "-"
        echo -e "  ${C}1.${N}  ${W}Import cookie file${N}       ${DIM}(paste path to cookies.txt)${N}"
        echo -e "  ${C}2.${N}  ${W}Paste cookie manually${N}    ${DIM}(type/paste Netscape format)${N}"
        echo -e "  ${C}3.${N}  ${W}Test cookie${N}              ${DIM}(verify with YouTube)${N}"
        echo -e "  ${C}4.${N}  ${W}Test with Facebook${N}       ${DIM}(verify with Facebook)${N}"
        echo -e "  ${C}5.${N}  ${W}View cookie info${N}         ${DIM}(show domains in file)${N}"
        echo -e "  ${C}6.${N}  ${W}Delete cookie${N}            ${DIM}(remove saved cookie)${N}"
        echo -e "  ${C}7.${N}  ${W}How to get cookies.txt${N}   ${DIM}(instructions)${N}"
        echo -e "  ${C}8.${N}  ${W}Cookie profiles${N}          ${DIM}(save/switch multiple accounts)${N}"
        echo -e "  ${C}9.${N}  ${W}Lock / Unlock cookie${N}     ${DIM}(encrypt with passphrase)${N}"
        separator "-"
        echo -ne "  ${Y}Select (1-9 / Enter=back): ${N}"
        read -r CK_OPT

        case "$CK_OPT" in

            # ── 1. Import from file path (TXT or JSON) ────────────────────
            1)
                echo ""
                echo -e "  ${DIM}Supported formats: cookies.txt (Netscape) or cookies.json (J2TEAM)${N}"
                echo -e "  ${DIM}Example: /sdcard/Download/cookies.json${N}"
                echo -ne "  ${C}Path: ${N}"
                read -r CK_PATH
                CK_PATH="${CK_PATH/#\~/$HOME}"
                if [ -z "$CK_PATH" ]; then
                    warn_msg "Cancelled."
                elif [ ! -f "$CK_PATH" ]; then
                    error_msg "File not found: ${CK_PATH}"
                    echo -e "  ${DIM}Make sure the path is correct and the file exists.${N}"
                else
                    local EXT="${CK_PATH##*.}"
                    if [[ "$EXT" == "json" ]] || python3 -c "import json,sys; json.load(open(sys.argv[1])); sys.exit(0)" "$CK_PATH" 2>/dev/null; then
                        info_msg "Detected JSON format. Converting..."
                        python3 - "$CK_PATH" "$COOKIE_FILE" << 'PYEOF'
import json, sys
try:
    with open(sys.argv[1], "r") as f:
        data = json.load(f)
except Exception as e:
    print(f"  \033[0;31m[!] Failed to parse JSON: {e}\033[0m")
    sys.exit(1)

if isinstance(data, list):
    cookies = data
elif isinstance(data, dict):
    cookies = data.get("cookies", [])
else:
    print("  \033[0;31m[!] Unrecognized JSON structure.\033[0m")
    sys.exit(1)

lines = ["# Netscape HTTP Cookie File", "# Converted from JSON by ADM"]
count = 0
for c in cookies:
    try:
        domain  = c.get("domain", "")
        flag    = "TRUE" if domain.startswith(".") else "FALSE"
        path    = c.get("path", "/")
        secure  = "TRUE" if c.get("secure", False) else "FALSE"
        expires = str(int(c.get("expirationDate", c.get("expires", 0)) or 0))
        name    = c.get("name", "")
        value   = c.get("value", "")
        if domain and name:
            lines.append(f"{domain}\t{flag}\t{path}\t{secure}\t{expires}\t{name}\t{value}")
            count += 1
    except:
        continue

with open(sys.argv[2], "w") as f:
    f.write("\n".join(lines) + "\n")
print(f"  \033[0;32m[+] Converted {count} cookies to Netscape format.\033[0m")
PYEOF
                        if [ $? -eq 0 ]; then
                            success_msg "JSON cookie imported successfully!"
                        else
                            error_msg "JSON conversion failed."
                        fi
                    else
                        if grep -q "Netscape HTTP Cookie" "$CK_PATH" 2>/dev/null || \
                           grep -qE "^\S+\s+(TRUE|FALSE)\s+/" "$CK_PATH" 2>/dev/null; then
                            cp "$CK_PATH" "$COOKIE_FILE"
                            success_msg "Cookie imported successfully!"
                            local ENT; ENT=$(grep -c "^[^#]" "$COOKIE_FILE" 2>/dev/null || echo 0)
                            info_msg "Entries: ${ENT}"
                        else
                            warn_msg "File format not recognized."
                            echo -ne "  ${Y}Import anyway? (y/N): ${N}"
                            read -r FORCE
                            if [[ "$FORCE" =~ ^[Yy]$ ]]; then
                                cp "$CK_PATH" "$COOKIE_FILE"
                                success_msg "Cookie imported (unverified format)."
                            else
                                info_msg "Import cancelled."
                            fi
                        fi
                    fi
                fi
                sleep 2 ;;

            # ── 2. Paste cookie manually ───────────────────────────────────
            2)
                echo ""
                echo -e "  ${DIM}Paste your cookie content below.${N}"
                echo -e "  ${DIM}First line should be: # Netscape HTTP Cookie File${N}"
                echo -e "  ${Y}  Type END on a new line when done.${N}"
                echo ""
                local PASTE_TMP; PASTE_TMP=$(mktemp "${TMP_DIR}/adm_ck_XXXXXX.txt")
                echo "# Netscape HTTP Cookie File" > "$PASTE_TMP"
                while IFS= read -r PASTE_LINE; do
                    [ "$PASTE_LINE" = "END" ] && break
                    echo "$PASTE_LINE" >> "$PASTE_TMP"
                done
                local PLINES; PLINES=$(grep -c "^[^#]" "$PASTE_TMP" 2>/dev/null || echo 0)
                if [ "$PLINES" -gt 0 ]; then
                    cp "$PASTE_TMP" "$COOKIE_FILE"
                    success_msg "Cookie saved! Entries: ${PLINES}"
                else
                    error_msg "No valid cookie entries found."
                fi
                rm -f "$PASTE_TMP"
                sleep 2 ;;

            # ── 3. Test with YouTube ───────────────────────────────────────
            3)
                echo ""
                if [ ! -s "$COOKIE_FILE" ]; then
                    error_msg "No cookie file. Import one first."
                    sleep 2; continue
                fi
                info_msg "Testing cookie with YouTube..."
                echo -e "  ${DIM}Connecting...${N}"
                local TEST_OUT
                TEST_OUT=$(yt-dlp --cookies "$COOKIE_FILE" \
                    --skip-download --quiet --no-warnings \
                    --print "%(uploader)s | %(title)s" \
                    "https://www.youtube.com/watch?v=dQw4w9WgXcQ" 2>&1)
                if [ $? -eq 0 ] && [ -n "$TEST_OUT" ]; then
                    success_msg "Cookie is VALID and working!"
                    echo -e "  ${DIM}  Test video: ${TEST_OUT:0:60}${N}"
                else
                    error_msg "Cookie test FAILED."
                    echo -e "  ${DIM}  - Cookie may be expired (re-export from browser)${N}"
                    echo -e "  ${DIM}  - Wrong format (must be Netscape/cookies.txt)${N}"
                    echo -e "  ${DIM}  - Network issue or YouTube blocked the request${N}"
                fi
                echo ""
                echo -ne "  ${DIM}Press Enter to continue...${N}"; read -r ;;

            # ── 4. Test with Facebook ──────────────────────────────────────
            4)
                echo ""
                if [ ! -s "$COOKIE_FILE" ]; then
                    error_msg "No cookie file. Import one first."
                    sleep 2; continue
                fi
                echo -ne "  ${W}Enter a Facebook video URL to test: ${N}"
                read -r FB_URL
                if [[ "$FB_URL" != http* ]]; then
                    error_msg "Invalid URL."
                    sleep 1; continue
                fi
                info_msg "Testing Facebook cookie..."
                local FB_OUT
                FB_OUT=$(yt-dlp --cookies "$COOKIE_FILE" \
                    --skip-download --quiet --no-warnings \
                    --print "%(title)s" "$FB_URL" 2>&1)
                if [ $? -eq 0 ] && [ -n "$FB_OUT" ]; then
                    success_msg "Cookie is VALID for Facebook!"
                    echo -e "  ${DIM}  Video: ${FB_OUT:0:60}${N}"
                else
                    error_msg "Facebook cookie test FAILED."
                    echo -e "  ${DIM}  Try re-exporting cookie while logged into Facebook.${N}"
                fi
                echo ""
                echo -ne "  ${DIM}Press Enter to continue...${N}"; read -r ;;

            # ── 5. View cookie domains ─────────────────────────────────────
            5)
                echo ""
                if [ ! -s "$COOKIE_FILE" ]; then
                    error_msg "No cookie loaded."
                    sleep 2; continue
                fi
                separator "-"
                center_text "COOKIE DOMAINS" "${C}"
                separator "-"
                grep -v "^#" "$COOKIE_FILE" 2>/dev/null | \
                    awk '{print $1}' | sort -u | \
                    while read -r DOM; do
                        [ -n "$DOM" ] && echo -e "  ${DIM}${C}•${N}  ${W}${DOM}${N}"
                    done
                separator "-"
                echo -ne "  ${DIM}Press Enter to continue...${N}"; read -r ;;

            # ── 6. Delete cookie ───────────────────────────────────────────
            6)
                echo ""
                if [ ! -s "$COOKIE_FILE" ]; then
                    warn_msg "No cookie to delete."
                    sleep 1; continue
                fi
                echo -ne "  ${R}Delete saved cookie? This cannot be undone. (y/N): ${N}"
                read -r CONFIRM
                if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
                    rm -f "$COOKIE_FILE"
                    success_msg "Cookie deleted."
                else
                    info_msg "Cancelled."
                fi
                sleep 1 ;;

            # ── 7. How-to instructions ─────────────────────────────────────
            7)
                clear 2>/dev/null
                separator "="
                center_text "HOW TO GET cookies.txt" "${BOLD}${C}"
                separator "="
                echo ""
                echo -e "  ${BOLD}${W}METHOD 1 — Browser Extension (Recommended)${N}"
                echo -e "  ${DIM}─────────────────────────────────────────────${N}"
                echo -e "  ${C}1.${N} Install extension in your browser:"
                echo -e "     ${Y}Chrome/Edge${N}: 'Get cookies.txt LOCALLY'"
                echo -e "     ${Y}Firefox${N}    : 'cookies.txt' by Lennon Hill"
                echo ""
                echo -e "  ${C}2.${N} Open ${W}youtube.com${N} or ${W}facebook.com${N}"
                echo -e "     Make sure you are ${G}logged in${N}"
                echo ""
                echo -e "  ${C}3.${N} Click the extension icon"
                echo -e "     Select ${Y}Export${N} → Save as ${W}cookies.txt${N}"
                echo ""
                echo -e "  ${C}4.${N} Transfer to this device and use option ${Y}1${N} to import"
                echo ""
                separator "-"
                echo ""
                echo -e "  ${BOLD}${W}METHOD 2 — Edge Browser (Manual)${N}"
                echo -e "  ${DIM}─────────────────────────────────────────────${N}"
                echo -e "  ${C}1.${N} Open Edge → Press ${Y}F12${N} (DevTools)"
                echo -e "  ${C}2.${N} Go to ${Y}Application${N} tab → ${Y}Storage${N} → ${Y}Cookies${N}"
                echo -e "  ${C}3.${N} Find the site, copy values manually"
                echo -e "     ${DIM}(Extension method is much easier)${N}"
                echo ""
                separator "-"
                echo ""
                echo -e "  ${BOLD}${W}COOKIE FILE FORMAT (Netscape):${N}"
                echo -e "  ${DIM}─────────────────────────────────────────────${N}"
                echo -e "  ${DIM}# Netscape HTTP Cookie File${N}"
                echo -e "  ${DIM}.youtube.com  TRUE  /  TRUE  0  COOKIE_NAME  VALUE${N}"
                echo ""
                separator "="
                echo -ne "  ${DIM}Press Enter to continue...${N}"; read -r ;;

            8) cookie_profiles_menu ;;
            9) cookie_lock_menu ;;

            *) break ;;
        esac
    done
}

# ================================================================
# SETTINGS
# ================================================================
# ================================================================
# QUICK PROFILES — one-tap preset bundles of common settings
# ================================================================
apply_quick_profile() {
    clear 2>/dev/null
    separator "="
    center_text "QUICK PROFILES" "${BOLD}${C}"
    separator "="
    echo ""
    echo -e "  ${W}1${N}  Music Mode     ${DIM}audio-only, thumbnail+metadata on${N}"
    echo -e "  ${W}2${N}  Lecture Mode   ${DIM}480p, subtitles on, data-friendly${N}"
    echo -e "  ${W}3${N}  Best Quality   ${DIM}reset to defaults, no limits${N}"
    echo ""
    echo -ne "  ${Y}Select (1-3 / Enter=cancel): ${N}"
    read -r P
    case "$P" in
        1)
            set_setting save_thumbnail "true"
            set_setting embed_metadata "true"
            set_setting save_subtitle "false"
            set_setting sponsorblock "false"
            success_msg "Music Mode applied — pick 'Audio MP3' (option 7) when downloading" ;;
        2)
            set_setting save_subtitle "true"
            set_setting embed_metadata "true"
            set_setting save_thumbnail "false"
            set_setting sponsorblock "false"
            success_msg "Lecture Mode applied — pick 480p (option 5) when downloading" ;;
        3)
            set_setting save_thumbnail "false"
            set_setting save_subtitle "false"
            set_setting embed_metadata "true"
            set_setting sponsorblock "false"
            success_msg "Reset to default settings" ;;
        *) return ;;
    esac
    sleep 2
}

show_settings() {
    while true; do
        clear 2>/dev/null
        separator "="
        center_text "SETTINGS" "${BOLD}${C}"
        separator "="

        local SPD PROXY THUMB SUB META
        SPD=$(get_setting speed_limit)
        PROXY=$(get_setting proxy)
        THUMB=$(get_setting save_thumbnail)
        SUB=$(get_setting save_subtitle)
        META=$(get_setting embed_metadata)

        local SPD_DISP SPD_NOTE
        if [ -z "$SPD" ]; then
            SPD_DISP="${DIM}unlimited${N}"; SPD_NOTE="${DIM}no limit${N}"
        else
            SPD_DISP="${G}[ ${SPD} ]${N}"; SPD_NOTE="${G}active${N}"
        fi

        local PROXY_DISP PROXY_NOTE
        if [ -z "$PROXY" ]; then
            PROXY_DISP="${DIM}[  off  ]${N}"; PROXY_NOTE="${DIM}not set${N}"
        else
            PROXY_DISP="${G}[ on ]${N}"; PROXY_NOTE="${G}active${N}"
        fi

        local THUMB_DISP THUMB_NOTE
        [ "$THUMB" = "true" ] && THUMB_DISP="${G}[  ON   ]${N}" && THUMB_NOTE="${G}saved with downloads${N}" \
                               || { THUMB_DISP="${DIM}[  OFF  ]${N}"; THUMB_NOTE="${DIM}disabled${N}"; }

        local SUB_DISP SUB_NOTE
        [ "$SUB"  = "true" ] && SUB_DISP="${G}[  ON   ]${N}"  && SUB_NOTE="${G}English subtitles saved${N}" \
                              || { SUB_DISP="${DIM}[  OFF  ]${N}";  SUB_NOTE="${DIM}disabled${N}"; }

        local META_DISP META_NOTE
        [ "$META" = "true" ] && META_DISP="${G}[  ON   ]${N}" && META_NOTE="${G}embedded in files${N}" \
                              || { META_DISP="${DIM}[  OFF  ]${N}"; META_NOTE="${DIM}disabled${N}"; }

        local CK_STATUS CK_NOTE
        if [ -s "$COOKIE_FILE" ]; then
            local _CK_ENT; _CK_ENT=$(grep -c "^[^#]" "$COOKIE_FILE" 2>/dev/null || echo 0)
            CK_STATUS="${G}[loaded ]${N}"
            CK_NOTE="${G}active — ${_CK_ENT} entries  →  manage: select 6${N}"
        else
            CK_STATUS="${R}[ none  ]${N}"
            CK_NOTE="${Y}not set — YouTube/Facebook may fail  →  select 6${N}"
        fi

        local SB SUBLANG
        SB=$(get_setting sponsorblock)
        SUBLANG=$(get_setting subtitle_lang); [ -z "$SUBLANG" ] && SUBLANG="en"
        local SB_DISP SB_NOTE
        [ "$SB" = "true" ] && SB_DISP="${G}[  ON   ]${N}" && SB_NOTE="${G}sponsor segments removed${N}" \
                           || { SB_DISP="${DIM}[  OFF  ]${N}"; SB_NOTE="${DIM}disabled${N}"; }

        local ARIA_DISP ARIA_NOTE
        if ! command -v aria2c &>/dev/null; then
            ARIA_DISP="${DIM}[ absent]${N}"; ARIA_NOTE="${DIM}not installed — will auto-install next launch${N}"
        elif [ "$(get_setting use_aria2c)" = "false" ]; then
            ARIA_DISP="${DIM}[  OFF  ]${N}"; ARIA_NOTE="${DIM}using yt-dlp's own downloader${N}"
        else
            ARIA_DISP="${G}[  ON   ]${N}"; ARIA_NOTE="${G}16-connection turbo download${N}"
        fi

        local UPD_URL UPD_DISP
        UPD_URL=$(get_setting update_url)
        [ -z "$UPD_URL" ] && UPD_DISP="${DIM}not set${N}" || UPD_DISP="${G}[ set ]${N}"

        echo ""
        printf "  ${C}%-3s${N}  ${W}%-16s${N}  %-20b  %b\n" "1." "Speed Limit"  "$SPD_DISP"   "$SPD_NOTE"
        printf "  ${C}%-3s${N}  ${W}%-16s${N}  %-20b  %b\n" "2." "Proxy"        "$PROXY_DISP" "$PROXY_NOTE"
        echo ""
        printf "  ${C}%-3s${N}  ${W}%-16s${N}  %-20b  %b\n" "3." "Thumbnail"    "$THUMB_DISP" "$THUMB_NOTE"
        printf "  ${C}%-3s${N}  ${W}%-16s${N}  %-20b  %b\n" "4." "Subtitle"     "$SUB_DISP"   "$SUB_NOTE"
        printf "  ${C}%-3s${N}  ${W}%-18s${N}  %-20b  %b\n" "4b." "Sub Language" "${DIM}[ ${SUBLANG} ]${N}" "${DIM}current subtitle lang${N}"
        printf "  ${C}%-3s${N}  ${W}%-16s${N}  %-20b  %b\n" "5." "Metadata"     "$META_DISP"  "$META_NOTE"
        printf "  ${C}%-3s${N}  ${W}%-16s${N}  %-20b  %b\n" "7." "SponsorBlock" "$SB_DISP"    "$SB_NOTE"
        printf "  ${C}%-3s${N}  ${W}%-16s${N}  %-20b  %b\n" "10." "Fast Downloader" "$ARIA_DISP" "$ARIA_NOTE"
        echo ""
        printf "  ${C}%-3s${N}  ${W}%-16s${N}  %-20b  %b\n" "6." "Cookie"       "$CK_STATUS"  "$CK_NOTE"
        printf "  ${C}%-3s${N}  ${W}%-16s${N}\n" "8." "Speed Test"
        printf "  ${C}%-3s${N}  ${W}%-16s${N}\n" "9." "Update yt-dlp"
        printf "  ${C}%-3s${N}  ${W}%-16s${N}  %-20b\n" "11." "Update URL" "$UPD_DISP"
        printf "  ${C}%-3s${N}  ${W}%-16s${N}\n" "12." "Update ADM now"
        printf "  ${C}%-3s${N}  ${W}%-16s${N}\n" "13." "View error log"
        printf "  ${C}%-3s${N}  ${W}%-16s${N}  %-20b\n" "14." "Filename Format" "${DIM}[ $(_get_filename_template) ]${N}"
        printf "  ${C}%-3s${N}  ${W}%-16s${N}\n" "15." "Quick Profile"
        local MAXP; MAXP=$(get_setting max_parallel); [[ "$MAXP" =~ ^[0-9]+$ ]] || MAXP=1
        printf "  ${C}%-3s${N}  ${W}%-16s${N}  %-20b\n" "16." "Parallel Downloads" "${DIM}[ ${MAXP}x ]${N}"
        local AC_DISP
        [ "$(get_setting auto_compress)" = "true" ] && AC_DISP="${G}[  ON   ]${N}" || AC_DISP="${DIM}[  OFF  ]${N}"
        printf "  ${C}%-3s${N}  ${W}%-16s${N}  %-20b  %b\n" "17." "Auto Compress" "$AC_DISP" "${DIM}smaller file, slower${N}"

        local TG_DISP
        [ -n "$(get_setting telegram_bot_token)" ] && [ -n "$(get_setting telegram_chat_id)" ] \
            && TG_DISP="${G}[  ON   ]${N}" || TG_DISP="${DIM}[ not set ]${N}"
        printf "  ${C}%-3s${N}  ${W}%-16s${N}  %-20b\n" "18." "Telegram Alerts" "$TG_DISP"

        local WF_DISP
        [ "$(get_setting wifi_only)" = "true" ] && WF_DISP="${G}[  ON   ]${N}" || WF_DISP="${DIM}[  OFF  ]${N}"
        printf "  ${C}%-3s${N}  ${W}%-16s${N}  %-20b  %b\n" "19." "Wi-Fi Only" "$WF_DISP" "${DIM}warn before mobile data${N}"

        local DS_DISP
        [ "$(get_setting data_saver)" = "true" ] && DS_DISP="${G}[  ON   ]${N}" || DS_DISP="${DIM}[  OFF  ]${N}"
        printf "  ${C}%-3s${N}  ${W}%-16s${N}  %-20b  %b\n" "20." "Data Saver" "$DS_DISP" "${DIM}force 480p max${N}"

        local LK_DISP LG_DISP
        [ -n "$(get_setting app_pin_hash)" ] && LK_DISP="${G}[  ON   ]${N}" || LK_DISP="${DIM}[  OFF  ]${N}"
        [ "$(get_setting language)" = "bn" ] && LG_DISP="${G}[ বাংলা ]${N}" || LG_DISP="${DIM}[English]${N}"
        printf "  ${C}%-3s${N}  ${W}%-16s${N}  %-20b\n" "21." "App Lock (PIN)" "$LK_DISP"
        printf "  ${C}%-3s${N}  ${W}%-16s${N}  %-20b  %b\n" "22." "Language" "$LG_DISP" "${DIM}Bengali UI (partial)${N}"
        printf "  ${C}%-3s${N}  ${W}%-16s${N}\n" "23." "Backup settings"
        printf "  ${C}%-3s${N}  ${W}%-16s${N}\n" "24." "Restore backup"
        printf "  ${C}%-3s${N}  ${W}%-16s${N}\n" "25." "Channel Sync"
        printf "  ${C}%-3s${N}  ${W}%-16s${N}\n" "26." "Schedule downloads"
        local FL_VAL FC_VAL
        FL_VAL=$(get_setting file_layout); [ -z "$FL_VAL" ] && FL_VAL="type"
        FC_VAL=$(get_setting file_connections); [[ "$FC_VAL" =~ ^[0-9]+$ ]] || FC_VAL=8
        printf "  ${C}%-3s${N}  ${W}%-16s${N}  %-20b  %b\n" "27." "File Folders" "${G}[ ${FL_VAL} ]${N}" "${DIM}type / site / flat${N}"
        printf "  ${C}%-3s${N}  ${W}%-16s${N}  %-20b  %b\n" "28." "File Connections" "${G}[ ${FC_VAL}x ]${N}" "${DIM}parallel parts per file${N}"
        echo ""
        separator "="
        echo -e "  ${DIM}toggle: 3/4/5/7/10   |   Speed: 2M 500K   |   Proxy: socks5://ip:port${N}"
        separator "="
        echo -ne "  ${Y}Select (1-28 / Enter=back): ${N}"
        read -r OPT
        case "$OPT" in
            1)
                echo -ne "  ${W}Speed limit${N} (blank=unlimited): "
                read -r V
                set_setting speed_limit "$V"
                [ -z "$V" ] && success_msg "Speed limit removed — unlimited" \
                            || success_msg "Speed limit set: ${V}"
                sleep 1 ;;
            2)
                echo -ne "  ${W}Proxy URL${N} (blank=none): "
                read -r V
                set_setting proxy "$V"
                if [ -n "$V" ]; then
                    info_msg "Testing proxy..."
                    if curl -s --proxy "$V" --max-time 5 https://example.com -o /dev/null 2>/dev/null; then
                        success_msg "Proxy working: ${V}"
                    else
                        warn_msg "Proxy not responding. Saved anyway."
                    fi
                else
                    success_msg "Proxy removed"
                fi
                sleep 2 ;;
            3)
                [ "$(get_setting save_thumbnail)" = "true" ] && V="false" || V="true"
                set_setting save_thumbnail "$V"
                [ "$V" = "true" ] && success_msg "Thumbnail: ON" || success_msg "Thumbnail: OFF"
                sleep 1 ;;
            4)
                [ "$(get_setting save_subtitle)" = "true" ] && V="false" || V="true"
                set_setting save_subtitle "$V"
                [ "$V" = "true" ] && success_msg "Subtitle: ON" || success_msg "Subtitle: OFF"
                sleep 1 ;;
            4b) set_subtitle_lang ;;
            5)
                [ "$(get_setting embed_metadata)" = "true" ] && V="false" || V="true"
                set_setting embed_metadata "$V"
                [ "$V" = "true" ] && success_msg "Metadata: ON" || success_msg "Metadata: OFF"
                sleep 1 ;;
            6) cookie_manager ;;
            7)
                [ "$(get_setting sponsorblock)" = "true" ] && V="false" || V="true"
                set_setting sponsorblock "$V"
                [ "$V" = "true" ] && success_msg "SponsorBlock: ON — YouTube sponsor segments will be skipped" \
                                  || success_msg "SponsorBlock: OFF"
                sleep 1 ;;
            8) run_speed_test ;;
            9)
                info_msg "Updating yt-dlp..."
                auto_update_ytdlp
                local _VER; _VER=$(yt-dlp --version 2>/dev/null)
                success_msg "yt-dlp updated → ${_VER}"
                sleep 2 ;;
            10)
                if ! command -v aria2c &>/dev/null; then
                    warn_msg "aria2c not installed yet — it installs automatically on next launch."
                else
                    [ "$(get_setting use_aria2c)" = "false" ] && V="true" || V="false"
                    set_setting use_aria2c "$V"
                    [ "$V" = "true" ] && success_msg "Fast Downloader: ON (aria2c, 16 connections)" \
                                      || success_msg "Fast Downloader: OFF (yt-dlp default)"
                fi
                sleep 1 ;;
            11)
                echo -ne "  ${W}Update URL${N} (raw .sh link, blank=clear): "
                read -r V
                set_setting update_url "$V"
                [ -z "$V" ] && success_msg "Update URL cleared" || success_msg "Update URL saved"
                sleep 1 ;;
            12)
                self_update
                echo -ne "  ${DIM}Press Enter to continue...${N}"; read -r ;;
            13) show_log ;;
            14)
                echo -e "  ${DIM}Placeholders: %(title)s %(uploader)s %(upload_date)s %(ext)s${N}"
                echo -ne "  ${W}Filename format${N} (Enter=default): "
                read -r V
                [ -z "$V" ] && V="%(title)s.%(ext)s"
                set_setting filename_template "$V"
                success_msg "Filename format saved: ${V}"
                sleep 1 ;;
            15) apply_quick_profile ;;
            16)
                echo -e "  ${DIM}More parallel downloads = faster batches but more data/RAM use.${N}"
                echo -ne "  ${W}How many at once${N} (1-4): "
                read -r V
                [[ "$V" =~ ^[1-4]$ ]] || V=1
                set_setting max_parallel "$V"
                success_msg "Parallel downloads set to ${V}x"
                sleep 1 ;;
            17)
                [ "$(get_setting auto_compress)" = "true" ] && V="false" || V="true"
                set_setting auto_compress "$V"
                [ "$V" = "true" ] && success_msg "Auto Compress: ON (smaller files, slower)" \
                                   || success_msg "Auto Compress: OFF"
                sleep 1 ;;
            18)
                echo -e "  ${DIM}Create a bot via @BotFather on Telegram to get a token.${N}"
                echo -ne "  ${W}Bot Token${N} (Enter=keep current): "
                read -r V
                [ -n "$V" ] && set_setting telegram_bot_token "$V"
                echo -ne "  ${W}Chat ID${N} (Enter=keep current): "
                read -r V
                [ -n "$V" ] && set_setting telegram_chat_id "$V"
                if [ -n "$(get_setting telegram_bot_token)" ] && [ -n "$(get_setting telegram_chat_id)" ]; then
                    info_msg "Sending a test message..."
                    send_telegram "✓ ADM Telegram alerts are working!"
                    success_msg "Test sent — check your Telegram."
                else
                    warn_msg "Telegram alerts need both a token and a chat ID."
                fi
                sleep 2 ;;
            19)
                [ "$(get_setting wifi_only)" = "true" ] && V="false" || V="true"
                set_setting wifi_only "$V"
                [ "$V" = "true" ] && success_msg "Wi-Fi Only: ON (asks before using mobile data)" \
                                   || success_msg "Wi-Fi Only: OFF"
                sleep 1 ;;
            20)
                [ "$(get_setting data_saver)" = "true" ] && V="false" || V="true"
                set_setting data_saver "$V"
                [ "$V" = "true" ] && success_msg "Data Saver: ON (max 480p, saves data)" \
                                   || success_msg "Data Saver: OFF"
                sleep 1 ;;
            21) set_app_pin ;;
            22)
                if [ "$(get_setting language)" = "bn" ]; then V="en"; else V="bn"; fi
                set_setting language "$V"
                [ "$V" = "bn" ] && success_msg "ভাষা: বাংলা (আংশিক অনুবাদ)" || success_msg "Language: English"
                [ "$V" = "bn" ] && warn_msg "If Bengali text looks broken, switch back to English."
                sleep 2 ;;
            23) backup_settings; echo -ne "  ${DIM}Press Enter...${N}"; read -r ;;
            24) restore_settings; echo -ne "  ${DIM}Press Enter...${N}"; read -r ;;
            25) subscriptions_menu ;;
            26) schedule_downloads ;;
            27)
                echo -e "  ${DIM}1 = by type   (Files/Documents, Files/Archives, Files/Apps ...)${N}"
                echo -e "  ${DIM}2 = by site   (one folder per website)${N}"
                echo -e "  ${DIM}3 = one folder (Files)${N}"
                echo -ne "  ${W}Choose${N} (1-3): "
                read -r V
                case "$V" in
                    2) set_setting file_layout "site"; success_msg "File folders: by site" ;;
                    3) set_setting file_layout "flat"; success_msg "File folders: one folder" ;;
                    *) set_setting file_layout "type"; success_msg "File folders: by type" ;;
                esac
                sleep 1 ;;
            28)
                echo -e "  ${DIM}More connections = faster on big files. If a server blocks you, use 1-4.${N}"
                echo -ne "  ${W}Connections per file${N} (1-16): "
                read -r V
                [[ "$V" =~ ^[0-9]+$ ]] && [ "$V" -ge 1 ] && [ "$V" -le 16 ] || V=8
                set_setting file_connections "$V"
                success_msg "File connections: ${V}x"
                sleep 1 ;;
            *) break ;;
        esac
    done
}

# ================================================================
# PLATFORM DETECT
# ================================================================
get_platform() {
    local URL="${1,,}"
    if   [[ "$URL" == *"youtube.com"* || "$URL" == *"youtu.be"* ]];              then echo "YouTube"
    elif [[ "$URL" == *"facebook.com"* || "$URL" == *"fb.watch"* || "$URL" == *"fb.com"* ]]; then echo "Facebook"
    elif [[ "$URL" == *"instagram.com"* ]];   then echo "Instagram"
    elif [[ "$URL" == *"tiktok.com"* ]];      then echo "TikTok"
    elif [[ "$URL" == *"twitter.com"* || "$URL" == *"x.com"* ]]; then echo "Twitter"
    elif [[ "$URL" == *"vimeo.com"* ]];       then echo "Vimeo"
    elif [[ "$URL" == *"dailymotion.com"* ]]; then echo "Dailymotion"
    elif [[ "$URL" == *"twitch.tv"* ]];       then echo "Twitch"
    elif [[ "$URL" == *"soundcloud.com"* ]];  then echo "SoundCloud"
    elif [[ "$URL" == *"reddit.com"* ]];      then echo "Reddit"
    elif [[ "$URL" == *"rumble.com"* ]];      then echo "Rumble"
    elif [[ "$URL" == *"bilibili.com"* ]];    then echo "Bilibili"
    elif [[ "$URL" == *"pinterest.com"* ]];   then echo "Pinterest"
    elif [[ "$URL" == *"linkedin.com"* ]];    then echo "LinkedIn"
    elif [[ "$URL" == *"t.me"* ]];            then echo "Telegram"
    else
        echo "$1" | sed 's|https\?://||;s|www\.||;s|/.*||;s|\.[^.]*$||;s|.*\.||' \
            | awk '{print toupper(substr($0,1,1)) substr($0,2)}'
    fi
}

# ================================================================
# SAVE PATH
# ================================================================
get_save_path() {
    local PLATFORM; PLATFORM=$(get_platform "$1")
    if [ "$OS_TYPE" = "linux" ]; then
        echo -ne "  ${C}Save path${N} (Enter=${DIM}${BASE_SAVE}/${PLATFORM}/${N}): " >&2
        read -r CP
        if [ -n "$CP" ]; then mkdir -p "$CP"; echo "$CP"; return; fi
    fi
    local OUT="${BASE_SAVE}/${PLATFORM}"
    mkdir -p "$OUT"; echo "$OUT"
}

# ================================================================
# RESOLUTION MENU
# ================================================================
show_menu_simple() {
    line "-"
    printf "  ${BOLD}${C}%-5s  %-16s${N}\n" "#" "$(t "Resolution")"
    line "-"
    echo -e "  ${W}1${N}      $(t "Best Quality")"
    echo -e "  ${W}2${N}      2160p  (4K)"
    echo -e "  ${W}3${N}      1080p"
    echo -e "  ${W}4${N}      720p"
    echo -e "  ${W}5${N}      480p"
    echo -e "  ${W}6${N}      360p"
    echo -e "  ${W}7${N}      $(t "Audio MP3")"
    line "-"
}

# ================================================================
# FETCH VIDEO INFO
# ================================================================
# ================================================================
# YOUTUBE SEARCH — search by name, pick from results, no link needed
# ================================================================
run_youtube_search_pick() {
    _YTS_PICKED_URL=""
    echo -ne "  ${W}Search YouTube${N}: "
    read -r Q
    [ -z "$Q" ] && return
    info_msg "Searching..."
    local TMP; TMP=$(mktemp "${TMP_DIR}/adm_search_XXXXXX.json")
    yt-dlp "ytsearch5:${Q}" --dump-json --flat-playlist --quiet --no-warnings > "$TMP" 2>/dev/null

    if [ ! -s "$TMP" ]; then
        rm -f "$TMP"
        error_msg "No results found."
        return
    fi

    local -a IDS=() TITLES=()
    while IFS= read -r LN; do
        [ -z "$LN" ] && continue
        local ID TITLE
        ID=$(echo "$LN" | python3 -c "import json,sys
try:
    print(json.loads(sys.stdin.read()).get('id',''))
except: pass" 2>/dev/null)
        TITLE=$(echo "$LN" | python3 -c "import json,sys
try:
    print(json.loads(sys.stdin.read()).get('title','?')[:55])
except: pass" 2>/dev/null)
        [ -z "$ID" ] && continue
        IDS+=("$ID"); TITLES+=("${TITLE:-?}")
    done < "$TMP"
    rm -f "$TMP"

    if [ ${#IDS[@]} -eq 0 ]; then
        error_msg "No results found."
        return
    fi

    echo ""
    local i
    for i in "${!IDS[@]}"; do
        printf "  ${W}%d${N}  %s\n" "$(( i + 1 ))" "${TITLES[$i]}"
    done
    echo ""
    echo -ne "  ${Y}Pick number (Enter=cancel): ${N}"
    read -r PICK
    [[ "$PICK" =~ ^[0-9]+$ ]] || return
    local IDX=$(( PICK - 1 ))
    if [ "$IDX" -lt 0 ] || [ "$IDX" -ge "${#IDS[@]}" ]; then
        error_msg "Invalid pick"
        return
    fi
    _YTS_PICKED_URL="https://www.youtube.com/watch?v=${IDS[$IDX]}"
}

fetch_and_show() {
    local URL="$1"
    echo -e "\n${DIM}${C}  Fetching info...${N}"

    local TMP; TMP=$(mktemp "${TMP_DIR}/adm_info_XXXXXX.json")
    yt-dlp --dump-single-json --skip-download --no-playlist \
           --quiet --no-warnings "$URL" > "$TMP" 2>/dev/null

    local SZ; SZ=$(wc -c < "$TMP" 2>/dev/null || echo 0)
    if [ "$SZ" -lt 10 ]; then
        rm -f "$TMP"
        warn_msg "Could not fetch info. Updating yt-dlp..."
        auto_update_ytdlp
        yt-dlp --dump-single-json --skip-download --no-playlist \
               --quiet --no-warnings "$URL" > "$TMP" 2>/dev/null
        SZ=$(wc -c < "$TMP" 2>/dev/null || echo 0)
        if [ "$SZ" -lt 10 ]; then
            rm -f "$TMP"
            warn_msg "Showing menu without size info."
            show_menu_simple; return 2
        fi
    fi

    python3 - "$TMP" << 'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f: d = json.load(f)
except: sys.exit(1)

title = (d.get("title") or "?")[:60]
dur   = d.get("duration") or 0
m, s  = divmod(int(dur), 60)
print(f"\n  \033[1;37m{title}\033[0m")
print(f"  \033[2m\033[0;36m{m}:{s:02d}\033[0m")

fmts = d.get("formats", []); sm = {}; az = 0
for f in fmts:
    h  = f.get("height")
    fs = f.get("filesize") or f.get("filesize_approx") or 0
    vc = f.get("vcodec", "none")
    ac = f.get("acodec", "none")
    if h and vc != "none" and fs:
        if h not in sm or fs > sm[h]: sm[h] = fs
    if vc == "none" and ac != "none" and fs > az: az = fs

def sz(b):
    if not b: return "-"
    for u in ["B", "KB", "MB", "GB"]:
        if b < 1024: return f"{b:.1f} {u}"
        b /= 1024
    return f"{b:.1f} GB"

rows = [("1","Best Quality",None),("2","2160p (4K)",2160),("3","1080p",1080),
        ("4","720p",720),("5","480p",480),("6","360p",360),("7","Audio MP3",None)]

print(f"\n  \033[2m\033[0;36m{'─'*38}\033[0m")
print(f"  \033[1;37m{'#':<5}{'Resolution':<14}{'Size':>8}\033[0m")
print(f"  \033[2m\033[0;36m{'─'*38}\033[0m")
for k, label, h in rows:
    if k == "7": s2 = sz(az)
    elif h:
        v  = sm.get(h, 0); s2 = sz(v + az) if v else "-"
    else:
        bh = max(sm.keys()) if sm else None
        v  = sm.get(bh, 0) if bh else 0; s2 = sz(v + az) if v else "-"
    print(f"  \033[0;36m{k}\033[0m     \033[1;37m{label:<14}\033[0m\033[2m{s2:>8}\033[0m")
print(f"  \033[2m\033[0;36m{'─'*38}\033[0m")
PYEOF

    local RET=$?; rm -f "$TMP"
    [ $RET -ne 0 ] && show_menu_simple && return 2
    return 0
}

# ================================================================
# HLS DETECT
# FIX: Cached via file to avoid double yt-dlp network call
# ================================================================
_HLS_CACHE_URL=""
_HLS_CACHE_RESULT=1

detect_hls_from_url() {
    local URL="$1"
    # If we already checked this URL, reuse the result
    if [ "$_HLS_CACHE_URL" = "$URL" ]; then
        return "$_HLS_CACHE_RESULT"
    fi
    local TMP; TMP=$(mktemp "${TMP_DIR}/adm_hls_XXXXXX.json")
    yt-dlp --dump-single-json --skip-download --quiet --no-warnings \
        --no-playlist "$URL" > "$TMP" 2>/dev/null
    python3 - "$TMP" << 'PYEOF' 2>/dev/null
import json, sys
try:
    d    = json.load(open(sys.argv[1]))
    fmts = d.get('formats', [])
    is_hls = any(
        'm3u8' in (f.get('url','') or f.get('manifest_url',''))
        or f.get('protocol','') in ('m3u8','m3u8_native')
        for f in fmts
    )
    sys.exit(0 if is_hls else 1)
except:
    sys.exit(1)
PYEOF
    _HLS_CACHE_RESULT=$?
    _HLS_CACHE_URL="$URL"
    rm -f "$TMP"
    return "$_HLS_CACHE_RESULT"
}

# ================================================================
# PLAYLIST ITEM SELECTOR
# ================================================================
PLAYLIST_ITEMS=""

select_playlist_items() {
    local URL="$1"
    PLAYLIST_ITEMS=""
    separator "="
    center_text "PLAYLIST DETECTED" "${BOLD}${C}"
    separator "="
    info_msg "Loading playlist..."

    local TMP; TMP=$(mktemp "${TMP_DIR}/adm_pl_XXXXXX.json")
    yt-dlp --flat-playlist --dump-single-json --quiet --no-warnings \
        "$URL" > "$TMP" 2>/dev/null

    local COUNT
    COUNT=$(python3 - "$TMP" << 'PYEOF' 2>/dev/null
import json, sys
try:    d = json.load(open(sys.argv[1])); print(len(d.get('entries', [])))
except: print(0)
PYEOF
)

    if [ "$COUNT" -eq 0 ] 2>/dev/null; then
        rm -f "$TMP"
        warn_msg "Could not load playlist. Will download all."
        return 0
    fi

    local TITLE
    TITLE=$(python3 - "$TMP" << 'PYEOF' 2>/dev/null
import json, sys
try:    d = json.load(open(sys.argv[1])); print(d.get('title','Playlist')[:50])
except: print('Playlist')
PYEOF
)

    echo -e "\n  ${W}${TITLE}${N}  ${DIM}(${COUNT} items)${N}"
    line "-"

    python3 - "$TMP" << 'PYEOF' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    for i, e in enumerate(d.get('entries', []), 1):
        t   = e.get('title', '?')[:45]
        dur = e.get('duration') or 0
        m, s = divmod(int(dur), 60)
        print(f'  \033[0;36m{i:>3}.\033[0m  \033[1;37m{t:<45}\033[0m  \033[2m{m}:{s:02d}\033[0m')
except: pass
PYEOF

    rm -f "$TMP"
    line "-"
    echo -e "${DIM}  Enter=all  |  1,5,9  |  1-20  |  1,3,10-15${N}"
    echo -ne "  ${BOLD}${W}Select items${N}: "
    read -r ITEMS
    [ -n "$ITEMS" ] && PLAYLIST_ITEMS="$ITEMS"
    return 0
}

# ================================================================
# DOWNLOAD SCREEN UI HELPERS
# ================================================================

# Gradient bar — red→orange→yellow→green
_gradient_bar() {
    local FILLED="$1" TOTAL="$2"
    local i POS COLOR
    for (( i=0; i<TOTAL; i++ )); do
        if [ "$i" -lt "$FILLED" ]; then
            POS=$(( i * 100 / TOTAL ))
            if   [ "$POS" -lt 17 ]; then COLOR=196
            elif [ "$POS" -lt 34 ]; then COLOR=202
            elif [ "$POS" -lt 51 ]; then COLOR=208
            elif [ "$POS" -lt 68 ]; then COLOR=214
            elif [ "$POS" -lt 85 ]; then COLOR=226
            else                         COLOR=46
            fi
            printf "\033[38;5;%sm█\033[0m" "$COLOR"
        else
            printf "\033[38;5;238m░\033[0m"
        fi
    done
}

# Download info header — printed once
_print_dl_header() {
    local TITLE="$1" PLATFORM="$2" QUALITY="$3" SAVE_PATH="$4"
    local IDX="$5" TOTAL="$6"

    clear 2>/dev/null
    local TW; TW=$(tput cols 2>/dev/null || echo 70)
    [ "$TW" -lt 40 ] && TW=40

    local CTR=""
    [ -n "$IDX" ] && CTR="  [${IDX}/${TOTAL}]"

    printf "\033[38;5;33m"
    _repeat_char '━' "$TW"
    printf "\033[0m\n"
    printf "\033[38;5;33m ⬇  ADM\033[0m\033[38;5;244m%s\033[0m\n" "$CTR"
    printf "\033[38;5;240m"
    _repeat_char '─' "$TW"
    printf "\033[0m\n\n"

    local T_SHORT="${TITLE:0:$(( TW - 4 ))}"
    printf "  \033[1;97m%s\033[0m\n" "$T_SHORT"
    printf "  \033[38;5;244m%s  ·  %s\033[0m\n\n" "$PLATFORM" "$QUALITY"
    printf "  \033[38;5;244mFolder  \033[0m\033[38;5;244m%s\033[0m\n\n" "${SAVE_PATH:0:$(( TW - 12 ))}"
    printf "\033[38;5;240m"
    _repeat_char '─' "$TW"
    printf "\033[0m\n"
    printf "  \033[38;5;240mCtrl+C to cancel\033[0m\n\n"
}

# ── Smooth Progress Bar ──────────────────────────────────────────
# Renders 4 lines (bar + stats row + eta row + blank) and
# rewrites them in-place every update using tput cursor movement.
# Lines:
#   L1:  [████░░░░░]  73%
#   L2:   ↓ 2.4MiB/s   Total: 128.3 MiB   ETA: 00:45
#   L3:   ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
#   L4:  (blank spacing)
#
_PROG_LINES=4    # number of lines owned by progress block
_PROG_STARTED=0

_show_progress() {
    local P="${1:-0}" SPEED="${2:---}" ETA="${3:---}" TSZ="${4:---}" STATUS="${5:-↓}"
    local TW; TW=$(tput cols 2>/dev/null || echo 70)

    local BAR_W=$(( TW - 14 ))
    [ "$BAR_W" -gt 64 ] && BAR_W=64
    [ "$BAR_W" -lt 10 ] && BAR_W=10

    local FILLED=$(( P * BAR_W / 100 ))

    local PCT_CLR
    if   [ "$P" -lt 26 ]; then PCT_CLR=196
    elif [ "$P" -lt 51 ]; then PCT_CLR=208
    elif [ "$P" -lt 76 ]; then PCT_CLR=226
    else                       PCT_CLR=46
    fi

    local ICON="↓"
    [ "$STATUS" = "Merging"    ] && ICON="⚙"
    [ "$STATUS" = "Retrying"   ] && ICON="↺"
    [ "$STATUS" = "Extracting" ] && ICON="♪"

    # ETA reformat
    local ETA_DISP="$ETA"
    if [[ "$ETA" =~ ^([0-9]+):([0-9]+)$ ]]; then
        local em="${BASH_REMATCH[1]}" es="${BASH_REMATCH[2]}"
        [ "$em" -eq 0 ] && ETA_DISP="${es}s" || ETA_DISP="${em}m ${es}s"
    fi

    # First call: print placeholder lines so cursor-up has something to overwrite
    if [ "$_PROG_STARTED" = "0" ]; then
        printf "\n\n\n\n"
        _PROG_STARTED=1
    fi

    # Move cursor up N lines — use ANSI escape (more reliable than tput on Termux)
    printf "\033[%dA" "$_PROG_LINES"

    # ── Line 1: bar ───────────────────────────────────────────────
    printf "\033[2K"
    printf "  "
    _gradient_bar "$FILLED" "$BAR_W"
    printf "  \033[38;5;%sm\033[1m%3d%%\033[0m\n" "$PCT_CLR" "$P"

    # ── Line 2: stats ─────────────────────────────────────────────
    printf "\033[2K"
    printf "  \033[38;5;33m%s\033[0m" "$ICON"
    printf "  \033[38;5;244mSpeed\033[0m \033[1;97m%-12s\033[0m" "${SPEED:----}"
    printf "  \033[38;5;244mSize\033[0m \033[1;97m%-12s\033[0m" "${TSZ:----}"
    printf "  \033[38;5;244mETA\033[0m \033[38;5;226m%s\033[0m\n" "${ETA_DISP:----}"

    # ── Line 3: thin separator ────────────────────────────────────
    printf "\033[2K"
    printf "  \033[38;5;236m"
    _repeat_char '─' $(( TW - 4 ))
    printf "\033[0m\n"

    # ── Line 4: blank ─────────────────────────────────────────────
    printf "\033[2K\n"
}

# Success screen
_draw_success_screen() {
    local TITLE="$1" FNAME="$2" ELAPSED="$3" PLATFORM="$4"
    clear 2>/dev/null
    local TW; TW=$(tput cols 2>/dev/null || echo 70)
    local H=$(( ELAPSED / 3600 )) M=$(( (ELAPSED % 3600) / 60 )) S=$(( ELAPSED % 60 ))
    local EL="${M}m ${S}s"; [ "$H" -gt 0 ] && EL="${H}h ${M}m ${S}s"

    printf "\033[38;5;46m"
    _repeat_char '━' "$TW"
    printf "\033[0m\n\n"
    printf "\033[38;5;46m\033[1m  ✓  DOWNLOAD COMPLETE\033[0m\n\n"
    printf "  \033[38;5;244mTitle    \033[0m\033[1;97m%s\033[0m\n" "${TITLE:0:$(( TW - 14 ))}"
    printf "  \033[38;5;244mPlatform \033[0m\033[1;97m%s\033[0m\n" "$PLATFORM"
    printf "  \033[38;5;244mFile     \033[0m\033[1;97m%s\033[0m\n" "$FNAME"
    printf "  \033[38;5;244mTime     \033[0m\033[1;97m%s\033[0m\n\n" "$EL"
    printf "\033[38;5;46m"
    _repeat_char '━' "$TW"
    printf "\033[0m\n"
}

# Error screen
_draw_error_screen() {
    local TITLE="$1" ERR_MSG="$2" PLATFORM="$3" HINT="$4"
    clear 2>/dev/null
    local TW; TW=$(tput cols 2>/dev/null || echo 70)

    printf "\033[38;5;196m"
    _repeat_char '━' "$TW"
    printf "\033[0m\n\n"
    printf "\033[38;5;196m\033[1m  ✗  DOWNLOAD FAILED\033[0m\n\n"
    printf "  \033[38;5;244mTitle    \033[0m\033[1;97m%s\033[0m\n" "${TITLE:0:$(( TW - 14 ))}"
    printf "  \033[38;5;244mPlatform \033[0m\033[1;97m%s\033[0m\n\n" "$PLATFORM"
    printf "  \033[38;5;196mError:\033[0m  \033[38;5;244m%s\033[0m\n" "${ERR_MSG:0:$(( TW - 10 ))}"
    [ -n "$HINT" ] && printf "\n  \033[38;5;226m⚑  %s\033[0m\n" "$HINT"
    printf "\n\033[38;5;196m"
    _repeat_char '━' "$TW"
    printf "\033[0m\n"
}

# Batch list screen
_draw_batch_screen() {
    local CURR_IDX="$1" TOTAL_B="$2"
    shift 2
    clear 2>/dev/null
    local TW; TW=$(tput cols 2>/dev/null || echo 70)

    printf "\033[38;5;33m"
    _repeat_char '━' "$TW"
    printf "\033[0m\n"
    printf "  \033[1;97mBATCH DOWNLOAD\033[0m  \033[38;5;244m%d of %d\033[0m\n" "$CURR_IDX" "$TOTAL_B"
    printf "\033[38;5;240m"
    _repeat_char '─' "$TW"
    printf "\033[0m\n\n"

    for ITEM in "$@"; do
        local IT="${ITEM%%|*}"
        local REST="${ITEM#*|}"
        local ST="${REST%%|*}"
        local PC="${REST#*|}"
        [[ "$PC" =~ ^[0-9]+$ ]] || PC=0

        local ICON CLR
        case "$ST" in
            done)        ICON="✓"; CLR=46  ;;
            downloading) ICON="↓"; CLR=33  ;;
            failed)      ICON="✗"; CLR=196 ;;
            *)           ICON="○"; CLR=244 ;;
        esac

        local MW=$(( TW - 16 ))
        [ "$MW" -gt 40 ] && MW=40
        [ "$MW" -lt 10 ] && MW=10
        local MF=$(( PC * MW / 100 ))

        printf "  \033[38;5;%sm%s\033[0m  \033[1;97m%s\033[0m\n" "$CLR" "$ICON" "${IT:0:50}"
        printf "     "
        _gradient_bar "$MF" "$MW"
        printf "  \033[38;5;244m%d%%\033[0m\n\n" "$PC"
    done

    printf "\033[38;5;240m"
    _repeat_char '─' "$TW"
    printf "\033[0m\n"
}

# ================================================================
# PROGRESS STREAM — reads yt-dlp log and updates progress bar
# ================================================================
_stream_progress() {
    local _LOG="$1" _PID="$2" _STATUS_LABEL="${3:-Downloading}"
    local _LAST_PCT="" _CUR_PCT=0 _LAST_TSZ=""
    local _LAST_NOTIF_PCT=-10
    local _CUR_SPD="---" _CUR_ETA="---" _CUR_TSZ="---"

    while kill -0 "$_PID" 2>/dev/null; do
        if [ -s "$_LOG" ]; then
            local DL_LINE
            DL_LINE=$(tail -1 "$_LOG" 2>/dev/null)

            if echo "$DL_LINE" | grep -q "^\[download\]"; then
                local _PARSED
                _PARSED=$(python3 -c "
import sys, re
line = sys.argv[1]
pct = re.search(r'(\d+\.\d+)%', line)
spd = re.search(r'(\d+\.?\d*\s*\w+/s)', line)
eta = re.search(r'ETA\s+([\d:]+)', line)
tsz = re.search(r'of\s+([\d.]+\s*\w+iB)', line)
print('|'.join([
    pct.group(1) if pct else '',
    spd.group(1) if spd else '',
    eta.group(1) if eta else '',
    tsz.group(1) if tsz else '',
]))
" "$DL_LINE" 2>/dev/null)

                local _PCT _SPD _ETA _TSZ
                IFS='|' read -r _PCT _SPD _ETA _TSZ <<< "$_PARSED"

                [ -n "$_PCT" ] && {
                    _CUR_PCT="${_PCT%%.*}"
                    _CUR_PCT="${_CUR_PCT// /}"
                }
                [ -n "$_SPD" ] && _CUR_SPD="$_SPD"
                [ -n "$_ETA" ] && _CUR_ETA="$_ETA"
                [ -n "$_TSZ" ] && _CUR_TSZ="$_TSZ"

                if [ -n "$_PCT" ] && [ "$_PCT" != "$_LAST_PCT" ]; then
                    _show_progress "${_CUR_PCT:-0}" "$_CUR_SPD" "$_CUR_ETA" "$_CUR_TSZ" "$_STATUS_LABEL"
                    if [ $(( ${_CUR_PCT:-0} - _LAST_NOTIF_PCT )) -ge 10 ]; then
                        _update_progress_notification "${_CUR_PCT:-0}" "$_STATUS_LABEL"
                        _LAST_NOTIF_PCT="${_CUR_PCT:-0}"
                    fi
                    [ -n "$_CUR_SPD" ] && [ "$_CUR_SPD" != "---" ] && _speed_push "$_CUR_SPD"
                    _LAST_PCT="$_PCT"
                fi
                # unknown total size (no percentage): keep speed/size moving
                if [ -z "$_PCT" ] && [ -n "$_TSZ" ] && [ "$_TSZ" != "$_LAST_TSZ" ]; then
                    _show_progress "${_CUR_PCT:-0}" "$_CUR_SPD" "$_CUR_ETA" "$_CUR_TSZ" "$_STATUS_LABEL"
                    _LAST_TSZ="$_TSZ"
                fi

            elif echo "$DL_LINE" | grep -q "^\[Merger\]\|^\[ffmpeg\]\|^\[ExtractAudio\]"; then
                _show_progress 100 "---" "---" "$_CUR_TSZ" "Merging"
            fi
        fi
        sleep 0.3
    done
}

# ================================================================
# TEMP FILE CLEANUP — trap on exit/interrupt
# ================================================================
_ADM_TMPFILES=()
_adm_cleanup() {
    for f in "${_ADM_TMPFILES[@]}"; do rm -f "$f" 2>/dev/null; done
    rm -rf "$_ADM_PC_DIR" 2>/dev/null
}
trap '_adm_cleanup' EXIT INT TERM

_adm_mktemp() {
    local f; f=$(mktemp "${TMP_DIR}/adm_${1}_XXXXXX.${2:-txt}")
    _ADM_TMPFILES+=("$f")
    echo "$f"
}

# ================================================================
# BUILD YT-DLP FLAGS  (global scope — not nested inside do_download)
# ================================================================
_build_flags() {
    local _FRAG="$1" _URL="$2" _SAVE_PATH="$3"
    local _SPD; _SPD=$(get_setting speed_limit)
    local _PROXY; _PROXY=$(get_setting proxy)
    local _SUBLANG; _SUBLANG=$(get_setting subtitle_lang)
    [ -z "$_SUBLANG" ] && _SUBLANG="en"

    FLAGS=(
        --concurrent-fragments "$_FRAG"
        --buffer-size 16K
        --retries 15
        --fragment-retries 15
        --file-access-retries 5
        --socket-timeout 30
        --no-overwrites
        --output "${_SAVE_PATH}/$(_get_filename_template)"
        --print "after_move:filepath"
        --newline
    )
    [ "$_FRAG" -gt 1 ] && FLAGS+=(--http-chunk-size 10M)
    if [ -n "$PLAYLIST_ITEMS" ]; then
        FLAGS+=(--playlist-items "$PLAYLIST_ITEMS")
    else
        FLAGS+=(--no-playlist)
    fi
    [[ "$_URL" == *"pinterest.com"* ]] && FLAGS+=(--playlist-items 1)
    [ -n "$_SPD"   ] && FLAGS+=(--rate-limit "$_SPD")
    [ -n "$_PROXY" ] && FLAGS+=(--proxy "$_PROXY")
    if [[ "$_URL" == *"youtube.com"* || "$_URL" == *"youtu.be"* ]]; then
        [ "$(get_setting sponsorblock)" = "true" ] && \
            FLAGS+=(--sponsorblock-remove "sponsor,intro,outro,selfpromo,preview")
    fi
    [ "$(get_setting save_thumbnail)" = "true" ] && FLAGS+=(--write-thumbnail)
    [ "$(get_setting save_subtitle)"  = "true" ] && \
        FLAGS+=(--write-auto-sub --write-sub --sub-langs "$_SUBLANG" --convert-subs srt)
    [ "$(get_setting embed_metadata)" = "true" ] && FLAGS+=(--add-metadata --embed-metadata)
    [ -s "$COOKIE_FILE" ] && FLAGS+=(--cookies "$COOKIE_FILE")
}

# Extract saved filepath from yt-dlp log (python3 — no grep -oP)
_extract_saved_file() {
    local LOG="$1"
    python3 -c "
import sys, os
for line in open(sys.argv[1]):
    line = line.strip()
    if line.startswith('/') and not line.endswith('.part') and os.path.isfile(line):
        print(line)
" "$LOG" 2>/dev/null | tail -1
}

# ================================================================
# FILE ENGINE — download ANY file type (zip, apk, pdf, docs, images,
# audio, video, installers ...). Video / social links still go
# through yt-dlp; everything else goes through adm_fetch.py
# (resume, multi-connection, real file names, extension repair).
# ================================================================
declare -A _LINK_KIND=()
CLS_KIND=""
FILE_NAME_OVERRIDE=""
PB_kind=""; PB_name=""; PB_size=""; PB_size_h=""; PB_ctype=""
PB_ranges=""; PB_category=""; PB_final=""; PB_err=""
PAGE_PICKED=()
declare -a FARGS=()

_url_key()  { printf '%s' "$1" | md5sum | cut -c1-16; }
_url_host() { local h="${1#*://}"; h="${h%%/*}"; h="${h##*@}"; h="${h%%:*}"; printf '%s' "${h,,}"; }
_url_ext()  { local p="${1%%[?#]*}"; p="${p##*/}"; [[ "$p" == *.* ]] && { p="${p##*.}"; printf '%s' "${p,,}"; }; }

_STREAM_EXTS=" m3u8 mpd ism f4m "
_FILE_EXTS=" zip rar 7z tar gz tgz bz2 xz zst lz cab iso img dmg apk xapk apks apkm aab ipa exe msi deb rpm pkg appimage jar bat sh py pdf doc docx xls xlsx ppt pptx odt ods odp txt rtf csv epub mobi azw3 djvu md json xml sql db sqlite yaml yml log jpg jpeg png gif webp bmp svg ico tif tiff heic heif avif psd mp3 m4a aac flac wav ogg opus wma amr mid midi mp4 mkv webm avi mov wmv flv mpg mpeg 3gp m4v ogv ttf otf woff woff2 torrent ics vcf "

# Sites that yt-dlp understands (video / social). Everything else is probed.
_is_media_host() {
    local H; H=$(_url_host "$1")
    case "$H" in
        youtube.com|*.youtube.com|youtu.be|youtube-nocookie.com|*.youtube-nocookie.com) return 0 ;;
        facebook.com|*.facebook.com|fb.watch|fb.com|*.fb.com|fb.me)                    return 0 ;;
        instagram.com|*.instagram.com|tiktok.com|*.tiktok.com)                          return 0 ;;
        twitter.com|*.twitter.com|x.com|*.x.com)                                        return 0 ;;
        vimeo.com|*.vimeo.com|dailymotion.com|*.dailymotion.com|dai.ly)                 return 0 ;;
        twitch.tv|*.twitch.tv|soundcloud.com|*.soundcloud.com)                          return 0 ;;
        reddit.com|*.reddit.com|v.redd.it|redd.it|rumble.com|*.rumble.com)              return 0 ;;
        bilibili.com|*.bilibili.com|b23.tv|pinterest.*|*.pinterest.*|pin.it)            return 0 ;;
        linkedin.com|*.linkedin.com|t.me|bandcamp.com|*.bandcamp.com)                   return 0 ;;
        mixcloud.com|*.mixcloud.com|streamable.com|odysee.com|vk.com|*.vk.com|ok.ru)   return 0 ;;
        nicovideo.jp|*.nicovideo.jp|ted.com|*.ted.com|tumblr.com|*.tumblr.com)          return 0 ;;
        snapchat.com|*.snapchat.com|threads.net|*.threads.net|9gag.com)                 return 0 ;;
    esac
    return 1
}

# Common arguments for adm_fetch.py (connections, speed limit, proxy, cookies)
_fetch_common_args() {
    local _CONN="${1:-}" _SPD _PROXY
    [[ "$_CONN" =~ ^[0-9]+$ ]] || _CONN=$(get_setting file_connections)
    [[ "$_CONN" =~ ^[0-9]+$ ]] || _CONN=8
    [ "$_CONN" -lt 1 ]  && _CONN=1
    [ "$_CONN" -gt 16 ] && _CONN=16
    _SPD=$(get_setting speed_limit)
    _PROXY=$(get_setting proxy)
    FARGS=(--conn "$_CONN")
    [ -n "$_SPD" ]   && FARGS+=(--rate "$_SPD")
    [ -n "$_PROXY" ] && FARGS+=(--proxy "$_PROXY")
    [ -s "$COOKIE_FILE" ] && FARGS+=(--cookies "$COOKIE_FILE")
}

# Ask the server what a link really is. Fills PB_* (cached per URL).
_fetch_probe() {
    local URL="$1" KEY CF RAW K V
    PB_kind=""; PB_name=""; PB_size=""; PB_size_h=""; PB_ctype=""
    PB_ranges=""; PB_category=""; PB_final=""; PB_err=""
    mkdir -p "$_ADM_PC_DIR" 2>/dev/null
    KEY=$(_url_key "$URL"); CF="${_ADM_PC_DIR}/${KEY}.probe"
    if [ -s "$CF" ]; then
        RAW=$(cat "$CF" 2>/dev/null)
    else
        _fetch_common_args
        RAW=$(python3 "$FETCHER" probe "$URL" "${FARGS[@]}" 2>/dev/null)
        case "$RAW" in
            kind=file*|kind=html*) printf '%s\n' "$RAW" > "$CF" 2>/dev/null ;;
        esac
    fi
    while IFS='=' read -r K V; do
        case "$K" in
            kind)     PB_kind="$V" ;;
            name)     PB_name="$V" ;;
            size)     PB_size="$V" ;;
            size_h)   PB_size_h="$V" ;;
            ctype)    PB_ctype="$V" ;;
            ranges)   PB_ranges="$V" ;;
            category) PB_category="$V" ;;
            final)    PB_final="$V" ;;
            err)      PB_err="$V" ;;
        esac
    done <<< "$RAW"
    [ -z "$PB_kind" ] && PB_kind="error"
    return 0
}

# Decide how a link is handled: sets CLS_KIND to  media | file | page
#   media = yt-dlp (video/audio sites, streams)
#   file  = direct engine (any file type)
#   page  = unknown web page (tried as video first, then scanned for files)
_classify_url() {
    local URL="$1" KEY K="media" E
    KEY=$(_url_key "$URL")
    if [ -n "${_LINK_KIND[$KEY]:-}" ]; then CLS_KIND="${_LINK_KIND[$KEY]}"; return 0; fi
    if _is_media_host "$URL"; then
        K="media"
    else
        E=$(_url_ext "$URL")
        if   [ -n "$E" ] && [[ "$_STREAM_EXTS" == *" $E "* ]]; then K="media"
        elif [ -n "$E" ] && [[ "$_FILE_EXTS"   == *" $E "* ]]; then K="file"
        else
            dim_msg "Checking link type..."
            _fetch_probe "$URL"
            case "$PB_kind" in
                file) K="file" ;;
                html) K="page" ;;
                *)    K="media" ;;
            esac
        fi
    fi
    _LINK_KIND[$KEY]="$K"
    CLS_KIND="$K"
}

_mark_file_link() { _LINK_KIND[$(_url_key "$1")]="file"; }

# Where a plain file is saved:  type = Files/<Type>   site = <Site>   flat = Files
_file_save_path() {
    local CAT="${1:-Other}" SITE="${2:-Web}" LAYOUT OUT CP
    LAYOUT=$(get_setting file_layout)
    case "$LAYOUT" in
        site) OUT="${BASE_SAVE}/${SITE}" ;;
        flat) OUT="${BASE_SAVE}/Files" ;;
        *)    OUT="${BASE_SAVE}/Files/${CAT}" ;;
    esac
    if [ "$OS_TYPE" = "linux" ] && [ -t 0 ]; then
        echo -ne "  ${C}Save path${N} (Enter=${DIM}${OUT}/${N}): " >&2
        read -r CP
        [ -n "$CP" ] && OUT="$CP"
    fi
    mkdir -p "$OUT" 2>/dev/null
    printf '%s\n' "$OUT"
}

# Info card for a single plain-file link. Return 1 = user cancelled.
_show_file_card() {
    local URL="$1" TW NAME CAT ACT NEWN
    _fetch_probe "$URL"
    TW=$(tput cols 2>/dev/null || echo 60); [ "$TW" -gt 72 ] && TW=72; [ "$TW" -lt 40 ] && TW=40
    NAME="${PB_name:-$(basename "${URL%%[?#]*}")}"
    CAT="${PB_category:-Other}"
    echo ""
    printf "\033[38;5;33m"; _repeat_char '━' "$TW"; printf "\033[0m\n"
    printf "  \033[1;97mFILE DETECTED\033[0m  \033[38;5;244m(direct download)\033[0m\n"
    printf "\033[38;5;240m"; _repeat_char '─' "$TW"; printf "\033[0m\n"
    printf "  \033[38;5;244mName    \033[0m\033[1;97m%s\033[0m\n" "${NAME:0:$(( TW - 12 ))}"
    if [ "$PB_kind" = "file" ]; then
        printf "  \033[38;5;244mType    \033[0m\033[1;97m%s\033[0m\033[2m %s\033[0m\n" "$CAT" "${PB_ctype:+(${PB_ctype})}"
        printf "  \033[38;5;244mSize    \033[0m\033[1;97m%s\033[0m\n" "${PB_size_h:-unknown}"
        local _RES="no"; [ "$PB_ranges" = "1" ] && _RES="yes"
        printf "  \033[38;5;244mResume  \033[0m\033[1;97m%s\033[0m\n" "$_RES"
    else
        printf "  \033[38;5;208m  Could not read file info (%s) — will still try.\033[0m\n" "${PB_err:-no answer}"
    fi
    printf "\033[38;5;240m"; _repeat_char '─' "$TW"; printf "\033[0m\n"
    echo -ne "  ${W}Enter${N}=download   ${W}r${N}=rename   ${W}n${N}=cancel : "
    read -r ACT
    case "$ACT" in
        n|N|q|Q) return 1 ;;
        r|R)
            echo -ne "  ${W}New file name${N} (extension optional): "
            read -r NEWN
            [ -n "$NEWN" ] && FILE_NAME_OVERRIDE="$NEWN"
            ;;
    esac
    return 0
}

# Echo the real path of a downloaded file whose extension may be wrong
# (yt-dlp leaves "unknown_video" on files it cannot identify).
_fix_saved_ext() {
    local F="$1" B E NEWP
    [ -f "$F" ] || { printf '%s\n' "$F"; return; }
    B=$(basename "$F"); E="${B##*.}"; E="${E,,}"
    if [[ "$B" != *.* ]] || [[ "$E" =~ ^(unknown_video|unknown_audio|unknown|download|tmp)$ ]]; then
        NEWP=$(python3 "$FETCHER" fixext "$F" 2>/dev/null | tail -1)
        [ -n "$NEWP" ] && [ -f "$NEWP" ] && { printf '%s\n' "$NEWP"; return; }
    fi
    printf '%s\n' "$F"
}

# ================================================================
# DIRECT FILE DOWNLOAD — zip/apk/pdf/docs/images/audio/video/anything
# ================================================================
do_direct_download() {
    local URL="$1" IDX="$2" TOTAL="$3"
    local NAME_OVR="${FILE_NAME_OVERRIDE:-}"
    [ "${TOTAL:-1}" -gt 1 ] && NAME_OVR=""
    local PLATFORM; PLATFORM=$(get_platform "$URL")

    _fetch_probe "$URL"
    local CAT="${PB_category:-Other}"
    local DNAME="${NAME_OVR:-${PB_name:-$(basename "${URL%%[?#]*}")}}"

    local _DUP; _DUP=$(history_check_duplicate "$URL")
    if [ -n "$_DUP" ]; then
        warn_msg "Already downloaded on ${_DUP%%|*}: ${_DUP##*|}"
        echo -ne "  Download again? [y/N]: "
        local _DUP_CHOICE; read -r _DUP_CHOICE
        [[ "$_DUP_CHOICE" =~ ^[Yy]$ ]] || return 0
    fi

    local SAVE_PATH; SAVE_PATH=$(_file_save_path "$CAT" "$PLATFORM")
    check_resume "$SAVE_PATH"

    local START RC=1 SAVED_FILE="" ERRTXT="" ATTEMPT CONN_OVR="" LOG PID
    START=$(date +%s)
    _print_dl_header "$DNAME" "$PLATFORM" "File · ${CAT}${PB_size_h:+ · $PB_size_h}" \
        "$SAVE_PATH" "$IDX" "$TOTAL"

    for ATTEMPT in 1 2; do
        LOG=$(_adm_mktemp "dl")
        _fetch_common_args "$CONN_OVR"
        _PROG_STARTED=0
        if [ -n "$NAME_OVR" ]; then
            python3 "$FETCHER" get "$URL" --outdir "$SAVE_PATH" --name "$NAME_OVR" "${FARGS[@]}" > "$LOG" 2>&1 &
        else
            python3 "$FETCHER" get "$URL" --outdir "$SAVE_PATH" "${FARGS[@]}" > "$LOG" 2>&1 &
        fi
        PID=$!
        _stream_progress "$LOG" "$PID" "$([ "$ATTEMPT" -eq 1 ] && echo Downloading || echo Retrying)"
        wait "$PID"; RC=$?
        # Ctrl+C interrupts `wait` while the engine is still saving resume data
        if [ "$RC" -gt 128 ] && kill -0 "$PID" 2>/dev/null; then wait "$PID"; RC=$?; fi
        _clear_progress_notification

        SAVED_FILE=$(_extract_saved_file "$LOG")
        ERRTXT=$(grep '^ERROR:' "$LOG" 2>/dev/null | tail -1 | sed 's/^ERROR: *//')
        rm -f "$LOG" 2>/dev/null
        [ "$RC" -eq 0 ] && break
        case "$RC" in 2|4|5|6|130) break ;; esac     # retrying cannot help
        if [ "$ATTEMPT" -eq 1 ]; then
            warn_msg "Connection problem — retrying on a single connection (resumes)..."
            CONN_OVR=1; sleep 2
        fi
    done

    local ELAPSED=$(( $(date +%s) - START ))

    if [ "$RC" -eq 0 ] && [ -n "$SAVED_FILE" ]; then
        local FNAME; FNAME=$(basename "$SAVED_FILE")
        update_stats "$ELAPSED"
        [ "$OS_TYPE" = "android" ] && trigger_media_scan "$SAVED_FILE"
        LAST_SAVED_FILE="$SAVED_FILE"
        history_add "$URL" "$FNAME" "$PLATFORM" "File · ${CAT}" "$FNAME"
        log_msg "INFO" "File downloaded OK: ${FNAME} [${PLATFORM}/${CAT}] in ${ELAPSED}s"
        _draw_success_screen "${CAT}${PB_size_h:+ · $PB_size_h}" "$FNAME" "$ELAPSED" "$PLATFORM"
        if [ ${#_SPEED_BUF[@]} -gt 0 ]; then
            echo ""
            printf "  \033[38;5;244mSpeed graph:\033[0m\n"
            _draw_speed_graph
        fi
        send_notification "✓ Download Complete" "$FNAME"
        printf "\n  \033[2mPress Enter to continue...\033[0m"; read -r
        return 0
    fi

    local HINT
    case "$RC" in
        2) case "$ERRTXT" in
               *401*|*403*) HINT="Server refused. Login needed? Add a cookie: cfg > 6" ;;
               *404*|*410*) HINT="Link is dead or expired. Get a fresh link." ;;
               *quota*)     HINT="Google Drive quota hit. Try later or use another copy." ;;
               *)           HINT="The server returned an error." ;;
           esac ;;
        3)   HINT="Network problem. Check connection / VPN, then retry — it resumes." ;;
        4)   HINT="This link is a web page, not a file." ;;
        5)   HINT="Fix the proxy in cfg > 2." ;;
        6)   HINT="Secure connection (SSL) problem." ;;
        130) HINT="Cancelled. Run the same link again to resume." ;;
        *)   HINT="Try again, or add a cookie / use a VPN." ;;
    esac
    log_msg "ERROR" "File download failed: ${DNAME} [${PLATFORM}] rc=${RC} — ${ERRTXT}"
    [ "$RC" -ne 130 ] && send_telegram "✗ Download failed: ${DNAME} [${PLATFORM}]"
    _draw_error_screen "$DNAME" "${ERRTXT:-Download failed}" "$PLATFORM" "$HINT"
    printf "\n  \033[2mPress Enter to continue...\033[0m"; read -r
    return 1
}

# "1,3,5-8" / "a" -> space separated indices (1..MAX)
_parse_selection() {
    local IN="${1// /}" MAX="$2" TOK i OUT=""
    local -a TOKS
    if [[ "${IN,,}" == "a" || "${IN,,}" == "all" ]]; then
        for (( i=1; i<=MAX; i++ )); do OUT+="$i "; done
        printf '%s' "$OUT"; return
    fi
    IFS=',' read -ra TOKS <<< "$IN"
    for TOK in "${TOKS[@]}"; do
        if [[ "$TOK" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            for (( i=BASH_REMATCH[1]; i<=BASH_REMATCH[2] && i<=MAX; i++ )); do
                [ "$i" -ge 1 ] && OUT+="$i "
            done
        elif [[ "$TOK" =~ ^[0-9]+$ ]] && [ "$TOK" -ge 1 ] && [ "$TOK" -le "$MAX" ]; then
            OUT+="$TOK "
        fi
    done
    printf '%s' "$OUT"
}

# Unknown web page: if it has no video, list the files it links to.
# Returns 0 when PAGE_PICKED holds links the user chose (all plain files),
# 1 when the normal video flow should continue.
_page_flow() {
    local URL="$1" RAW CT NM UR SEL I
    info_msg "Checking page for a video..."
    if yt-dlp --quiet --no-warnings --no-playlist --skip-download --print id "$URL" >/dev/null 2>&1; then
        return 1
    fi
    info_msg "No video found — scanning page for downloadable files..."
    _fetch_common_args
    RAW=$(python3 "$FETCHER" scan "$URL" "${FARGS[@]}" 2>/dev/null)
    local -a CATS=() NAMES=() URLS=()
    while IFS=$'\t' read -r CT NM UR; do
        [ -z "$UR" ] && continue
        CATS+=("$CT"); NAMES+=("$NM"); URLS+=("$UR")
    done <<< "$RAW"
    local COUNT=${#URLS[@]}
    [ "$COUNT" -eq 0 ] && { warn_msg "No downloadable files found on this page."; return 1; }

    local SHOW=$COUNT; [ "$SHOW" -gt 60 ] && SHOW=60
    local TW; TW=$(tput cols 2>/dev/null || echo 60)
    echo ""
    line "-"
    printf "  ${BOLD}${C}%d file link(s) found on this page${N}\n" "$COUNT"
    line "-"
    for (( I=0; I<SHOW; I++ )); do
        printf "  ${W}%3d${N}  ${DIM}%-9s${N} %s\n" "$(( I + 1 ))" "${CATS[$I]}" "${NAMES[$I]:0:$(( TW - 18 ))}"
    done
    [ "$COUNT" -gt "$SHOW" ] && dim_msg "(+$(( COUNT - SHOW )) more not shown)"
    line "-"
    echo -ne "  ${W}Pick${N} (e.g. 1,3,5-8  /  a=all  /  Enter=cancel): "
    local ANS; read -r ANS
    [ -z "$ANS" ] && return 1
    SEL=$(_parse_selection "$ANS" "$SHOW")
    [ -z "${SEL// /}" ] && { warn_msg "Nothing selected."; return 1; }
    PAGE_PICKED=()
    for I in $SEL; do
        PAGE_PICKED+=("${URLS[$(( I - 1 ))]}")
        _mark_file_link "${URLS[$(( I - 1 ))]}"
    done
    success_msg "${#PAGE_PICKED[@]} file(s) selected"
    return 0
}

# Repair files saved with a wrong or missing extension (e.g. ".unknown_video")
fix_extensions() {
    local FD OUT NCH LN
    echo ""
    info_msg "Repairs wrong/missing extensions (e.g. .unknown_video) by reading the real file type."
    echo -ne "  ${W}Folder${N} (Enter=${BASE_SAVE}): "
    read -r FD
    [ -z "$FD" ] && FD="$BASE_SAVE"
    [ -d "$FD" ] || { error_msg "Folder not found: $FD"; sleep 2; return; }
    OUT=$(python3 "$FETCHER" fixext "$FD" 2>/dev/null)
    while IFS= read -r LN; do
        [[ "$LN" == *" -> "* ]] && dim_msg "$LN"
    done <<< "$OUT"
    NCH=$(printf '%s\n' "$OUT" | sed -n 's/^DONE //p' | tail -1)
    success_msg "${NCH:-0} file(s) renamed"
    log_msg "INFO" "fix_extensions: ${NCH:-0} renamed in ${FD}"
    if [ "$OS_TYPE" = "android" ] && [ "${NCH:-0}" -gt 0 ] && command -v termux-media-scan &>/dev/null; then
        termux-media-scan -r "$FD" >/dev/null 2>&1 || true
    fi
    echo -ne "  ${DIM}Press Enter...${N}"; read -r
}

# ================================================================
# DOWNLOAD
# ================================================================
# ================================================================
# ARIA2C — optional multi-connection speed boost for non-HLS media
# ================================================================
# ================================================================
# AUTO COMPRESS — optional post-download re-encode to save space
# ================================================================
maybe_compress_file() {
    local F="$1"
    [ "$(get_setting auto_compress)" != "true" ] && { echo "$F"; return; }
    [ -f "$F" ] || { echo "$F"; return; }
    case "$F" in
        *.mp4|*.mkv|*.webm|*.mov|*.avi) ;;
        *) echo "$F"; return ;;
    esac
    command -v ffmpeg &>/dev/null || { echo "$F"; return; }

    local OUT="${F%.*}_adm_compressed.mp4"
    if ffmpeg -y -i "$F" -vcodec libx264 -crf 28 -preset fast \
              -acodec aac -b:a 128k "$OUT" &>/dev/null; then
        local OSZ NSZ
        OSZ=$(stat -c%s "$F" 2>/dev/null || echo 0)
        NSZ=$(stat -c%s "$OUT" 2>/dev/null || echo 0)
        if [ "${NSZ:-0}" -gt 0 ] && [ "${NSZ:-0}" -lt "${OSZ:-0}" ]; then
            mv -f "$OUT" "$F" 2>/dev/null
            log_msg "INFO" "Compressed $(basename "$F"): ${OSZ}B → ${NSZ}B"
        else
            rm -f "$OUT" 2>/dev/null
        fi
    else
        rm -f "$OUT" 2>/dev/null
    fi
    echo "$F"
}

_add_aria2_flags() {
    # Usage: _add_aria2_flags <FRAG_COUNT>   (appends to FLAGS array by name)
    local _FRAG="$1"
    [ "$(get_setting use_aria2c)" = "false" ] && return
    command -v aria2c &>/dev/null || return
    # Skip for HLS (FRAG_COUNT==1) — yt-dlp's native fragment downloader is better there
    [ "$_FRAG" -eq 1 ] && return
    FLAGS+=(--downloader aria2c --downloader-args "aria2c:-x 16 -s 16 -k 1M")
}

do_download() {
    local URL="$1" CHOICE="$2" IDX="$3" TOTAL="$4"

    # Plain files (zip, apk, pdf, docs, images, audio, any extension) use the
    # direct engine; video/social links continue below with yt-dlp.
    _classify_url "$URL"
    if [ "$CLS_KIND" = "file" ]; then
        do_direct_download "$URL" "$IDX" "$TOTAL"
        return $?
    fi

    # YouTube Mix/Radio detect — skip
    if echo "$URL" | grep -q "list=RD"; then
        _draw_error_screen "YouTube Mix/Radio" \
            "Mix/Radio playlists are not supported." \
            "YouTube" "Copy the direct video URL instead."
        printf "\n  \033[2mPress Enter to continue...\033[0m"; read -r
        return 1
    fi

    # Format with smart fallback chain
    local FMT LABEL
    case "$CHOICE" in
        1) FMT="bestvideo+bestaudio/best";
           LABEL="Best Quality" ;;
        2) FMT="bestvideo[height<=2160]+bestaudio/bestvideo[height<=1080]+bestaudio/best";
           LABEL="2160p (4K)" ;;
        3) FMT="bestvideo[height<=1080]+bestaudio/bestvideo[height<=720]+bestaudio/best";
           LABEL="1080p" ;;
        4) FMT="bestvideo[height<=720]+bestaudio/bestvideo[height<=480]+bestaudio/best";
           LABEL="720p" ;;
        5) FMT="bestvideo[height<=480]+bestaudio/bestvideo[height<=360]+bestaudio/best";
           LABEL="480p" ;;
        6) FMT="bestvideo[height<=360]+bestaudio/best";
           LABEL="360p" ;;
        7) FMT="bestaudio[ext=m4a]/bestaudio/best";
           LABEL="Audio MP3" ;;
        *) error_msg "Invalid choice"; return 1 ;;
    esac

    local PLATFORM SAVE_PATH
    PLATFORM=$(get_platform "$URL")
    SAVE_PATH=$(get_save_path "$URL")

    # HLS detect — auto fragment count
    local FRAG_COUNT=16
    if [ -z "$PLAYLIST_ITEMS" ]; then
        detect_hls_from_url "$URL" && FRAG_COUNT=1
    fi

    local -a FLAGS
    FLAGS=(
        --newline
        --concurrent-fragments "$FRAG_COUNT"
        --buffer-size 16K
        --retries 15
        --fragment-retries 15
        --file-access-retries 5
        --socket-timeout 30
        --no-overwrites
        --output "${SAVE_PATH}/$(_get_filename_template)"
        --print "after_move:filepath"
    )
    [ "$FRAG_COUNT" -gt 1 ] && FLAGS+=(--http-chunk-size 10M)
    _add_aria2_flags "$FRAG_COUNT"
    [ -n "${TRIM_SECTION:-}" ] && FLAGS+=(--download-sections "$TRIM_SECTION" --force-keyframes-at-cuts)
    if [ -n "$PLAYLIST_ITEMS" ]; then
        FLAGS+=(--playlist-items "$PLAYLIST_ITEMS")
    else
        FLAGS+=(--no-playlist)
    fi
    [[ "$URL" == *"pinterest.com"* ]] && FLAGS+=(--playlist-items 1)
    local _SPD; _SPD=$(get_setting speed_limit)
    local _PROXY; _PROXY=$(get_setting proxy)
    [ -n "$_SPD"   ] && FLAGS+=(--rate-limit "$_SPD")
    [ -n "$_PROXY" ] && FLAGS+=(--proxy "$_PROXY")
    if [[ "$URL" == *"youtube.com"* || "$URL" == *"youtu.be"* ]]; then
        [ "$(get_setting sponsorblock)" = "true" ] && \
            FLAGS+=(--sponsorblock-remove "sponsor,intro,outro,selfpromo,preview")
    fi
    [ "$(get_setting save_thumbnail)" = "true" ] && FLAGS+=(--write-thumbnail)
    if [ "$(get_setting save_subtitle)" = "true" ]; then
        local _SUBLANG; _SUBLANG=$(get_setting subtitle_lang)
        [ -z "$_SUBLANG" ] && _SUBLANG="en"
        FLAGS+=(--write-auto-sub --write-sub --sub-langs "$_SUBLANG" --convert-subs srt)
    fi
    [ "$(get_setting embed_metadata)" = "true" ] && FLAGS+=(--add-metadata --embed-metadata)
    [ -s "$COOKIE_FILE" ] && FLAGS+=(--cookies "$COOKIE_FILE")

    local START RET ELAPSED SAVED_FILE VID_TITLE=""
    START=$(date +%s)

    check_resume "$SAVE_PATH"

    # Duplicate check
    local _DUP; _DUP=$(history_check_duplicate "$URL")
    if [ -n "$_DUP" ]; then
        local _DUP_DATE; _DUP_DATE="${_DUP%%|*}"
        local _DUP_TITLE; _DUP_TITLE="${_DUP##*|}"
        warn_msg "Already downloaded on ${_DUP_DATE}: ${_DUP_TITLE}"
        echo -ne "  Download again? [y/N]: "
        read -r _DUP_CHOICE
        [[ "$_DUP_CHOICE" =~ ^[Yy]$ ]] || return 0
    fi

    info_msg "Fetching info..."
    VID_TITLE=$(yt-dlp --get-title --quiet --no-warnings --no-playlist "$URL" 2>/dev/null | head -1)
    [ -z "$VID_TITLE" ] && VID_TITLE="${URL:0:60}"

    # ── First attempt ──────────────────────────────────────────────
    _print_dl_header "$VID_TITLE" "$PLATFORM" "$LABEL" "$SAVE_PATH" "$IDX" "$TOTAL"

    local _DL_LOG; _DL_LOG=$(_adm_mktemp "dl")
    SAVED_FILE=""
    _PROG_STARTED=0

    if [ "$CHOICE" = "7" ]; then
        yt-dlp -f "$FMT" \
            --extract-audio --audio-format mp3 --audio-quality 0 \
            --embed-thumbnail "${FLAGS[@]}" "$URL" > "$_DL_LOG" 2>&1 &
    else
        yt-dlp -f "$FMT" \
            --merge-output-format mp4 \
            "${FLAGS[@]}" "$URL" > "$_DL_LOG" 2>&1 &
    fi
    local _YTPID=$!

    _stream_progress "$_DL_LOG" "$_YTPID" "Downloading"
    wait "$_YTPID"
    RET=$?
    _clear_progress_notification

    SAVED_FILE=$(_extract_saved_file "$_DL_LOG")
    ELAPSED=$(( $(date +%s) - START ))

    if [ $RET -eq 0 ]; then
        [ -n "$SAVED_FILE" ] && SAVED_FILE=$(_fix_saved_ext "$SAVED_FILE")
        [ -n "$SAVED_FILE" ] && SAVED_FILE=$(maybe_compress_file "$SAVED_FILE")
        update_stats "$ELAPSED"
        if [ "$OS_TYPE" = "android" ]; then
            if [ -n "$SAVED_FILE" ] && [ -f "$SAVED_FILE" ]; then
                trigger_media_scan "$SAVED_FILE"
            else
                find "$SAVE_PATH" -maxdepth 1 -newer "$DATA_DIR/setup_done" \
                    -type f 2>/dev/null | while read -r F; do trigger_media_scan "$F"; done
            fi
        fi
        local FNAME; FNAME=$(basename "${SAVED_FILE:-$SAVE_PATH}")
        LAST_SAVED_FILE="${SAVED_FILE:-$SAVE_PATH}"
        history_add "$URL" "$VID_TITLE" "$PLATFORM" "$LABEL" "$FNAME"
        log_msg "INFO" "Downloaded OK: ${VID_TITLE} [${PLATFORM}/${LABEL}] in ${ELAPSED}s"
        _draw_success_screen "$VID_TITLE" "$FNAME" "$ELAPSED" "$PLATFORM"
        if [ ${#_SPEED_BUF[@]} -gt 0 ]; then
            echo ""
            printf "  \033[38;5;244mSpeed graph:\033[0m\n"
            _draw_speed_graph
        fi
        send_notification "✓ Download Complete" "$VID_TITLE"
        printf "\n  \033[2mPress Enter to continue...\033[0m"; read -r
        return 0
    fi

    # ── Retry after yt-dlp update ─────────────────────────────────
    local HINT=""
    case "$PLATFORM" in
        YouTube)   HINT="Add YouTube cookie: cfg > 6" ;;
        Facebook)  HINT="Add Facebook cookie: cfg > 6" ;;
        Pinterest) HINT="Check URL is a direct pin, or add cookie" ;;
        Instagram) HINT="Add Instagram cookie: cfg > 6" ;;
        *)         HINT="Try enabling a VPN or adding a cookie" ;;
    esac

    log_msg "WARN" "First attempt failed: ${VID_TITLE} [${PLATFORM}] — $(tail -n 3 "$_DL_LOG" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g')"

    _draw_error_screen "$VID_TITLE" "Download failed. Updating yt-dlp and retrying..." \
        "$PLATFORM" "$HINT"
    sleep 2

    auto_update_ytdlp

    # Rebuild flags after update
    FLAGS=(
        --newline
        --concurrent-fragments "$FRAG_COUNT"
        --buffer-size 16K
        --retries 15
        --fragment-retries 15
        --file-access-retries 5
        --socket-timeout 30
        --no-overwrites
        --output "${SAVE_PATH}/$(_get_filename_template)"
        --print "after_move:filepath"
    )
    [ "$FRAG_COUNT" -gt 1 ] && FLAGS+=(--http-chunk-size 10M)
    _add_aria2_flags "$FRAG_COUNT"
    [ -n "${TRIM_SECTION:-}" ] && FLAGS+=(--download-sections "$TRIM_SECTION" --force-keyframes-at-cuts)
    if [ -n "$PLAYLIST_ITEMS" ]; then
        FLAGS+=(--playlist-items "$PLAYLIST_ITEMS")
    else
        FLAGS+=(--no-playlist)
    fi
    [[ "$URL" == *"pinterest.com"* ]] && FLAGS+=(--playlist-items 1)
    [ -n "$_SPD"   ] && FLAGS+=(--rate-limit "$_SPD")
    [ -n "$_PROXY" ] && FLAGS+=(--proxy "$_PROXY")
    if [[ "$URL" == *"youtube.com"* || "$URL" == *"youtu.be"* ]]; then
        [ "$(get_setting sponsorblock)" = "true" ] && \
            FLAGS+=(--sponsorblock-remove "sponsor,intro,outro,selfpromo,preview")
    fi
    [ "$(get_setting save_thumbnail)" = "true" ] && FLAGS+=(--write-thumbnail)
    if [ "$(get_setting save_subtitle)" = "true" ]; then
        local _SUBLANG2; _SUBLANG2=$(get_setting subtitle_lang)
        [ -z "$_SUBLANG2" ] && _SUBLANG2="en"
        FLAGS+=(--write-auto-sub --write-sub --sub-langs "$_SUBLANG2" --convert-subs srt)
    fi
    [ "$(get_setting embed_metadata)" = "true" ] && FLAGS+=(--add-metadata --embed-metadata)
    [ -s "$COOKIE_FILE" ] && FLAGS+=(--cookies "$COOKIE_FILE")

    _print_dl_header "$VID_TITLE" "$PLATFORM" "$LABEL" "$SAVE_PATH" "$IDX" "$TOTAL"

    local _RETRY_LOG; _RETRY_LOG=$(_adm_mktemp "retry")
    SAVED_FILE=""
    _PROG_STARTED=0

    if [ "$CHOICE" = "7" ]; then
        yt-dlp -f "$FMT" --extract-audio --audio-format mp3 --audio-quality 0 \
            --embed-thumbnail "${FLAGS[@]}" "$URL" > "$_RETRY_LOG" 2>&1 &
    else
        yt-dlp -f "$FMT" --merge-output-format mp4 "${FLAGS[@]}" "$URL" > "$_RETRY_LOG" 2>&1 &
    fi
    local _RETRY_PID=$!

    _stream_progress "$_RETRY_LOG" "$_RETRY_PID" "Retrying"
    wait "$_RETRY_PID"
    local _RETRY_RC=$?
    _clear_progress_notification

    SAVED_FILE=$(_extract_saved_file "$_RETRY_LOG")
    ELAPSED=$(( $(date +%s) - START ))

    if [ "$_RETRY_RC" -eq 0 ]; then
        [ -n "$SAVED_FILE" ] && SAVED_FILE=$(_fix_saved_ext "$SAVED_FILE")
        [ -n "$SAVED_FILE" ] && SAVED_FILE=$(maybe_compress_file "$SAVED_FILE")
        update_stats "$ELAPSED"
        if [ "$OS_TYPE" = "android" ]; then
            if [ -n "$SAVED_FILE" ] && [ -f "$SAVED_FILE" ]; then
                trigger_media_scan "$SAVED_FILE"
            else
                find "$SAVE_PATH" -maxdepth 1 -type f -newer "$DATA_DIR/setup_done" \
                    2>/dev/null | while read -r F; do trigger_media_scan "$F"; done
            fi
        fi
        local FNAME; FNAME=$(basename "${SAVED_FILE:-$SAVE_PATH}")
        LAST_SAVED_FILE="${SAVED_FILE:-$SAVE_PATH}"
        history_add "$URL" "$VID_TITLE" "$PLATFORM" "$LABEL" "$FNAME"
        log_msg "INFO" "Downloaded OK on retry: ${VID_TITLE} [${PLATFORM}/${LABEL}] in ${ELAPSED}s"
        _draw_success_screen "$VID_TITLE" "$FNAME" "$ELAPSED" "$PLATFORM"
        printf "\n  \033[2mPress Enter to continue...\033[0m"; read -r
        return 0
    fi

    log_msg "ERROR" "Failed after retry: ${VID_TITLE} [${PLATFORM}] — $(tail -n 5 "$_RETRY_LOG" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g')"
    send_telegram "✗ Download failed: ${VID_TITLE} [${PLATFORM}]"
    _draw_error_screen "$VID_TITLE" "Failed after retry." "$PLATFORM" "$HINT"
    printf "\n  \033[2mPress Enter to continue...\033[0m"; read -r
    return 1
}

# ================================================================
# PARALLEL BATCH DOWNLOADER — multiple links at once
# Fills the global SUCCESS / FAIL_LIST vars the caller expects.
# Returns 2 if parallel mode isn't active, so the caller can fall
# back to the normal one-at-a-time screen.
# ================================================================
run_parallel_batch() {
    local CHOICE="$1"; shift
    local -a P_LINKS=("$@")
    local P_TOTAL=${#P_LINKS[@]}

    local MAXP; MAXP=$(get_setting max_parallel)
    [[ "$MAXP" =~ ^[0-9]+$ ]] || MAXP=1
    [ "$MAXP" -lt 1 ] && MAXP=1
    [ "$MAXP" -gt 4 ] && MAXP=4

    if [ "$MAXP" -le 1 ] || [ "$P_TOTAL" -le 1 ]; then
        return 2
    fi

    local JOBDIR; JOBDIR="${TMP_DIR}/adm_parallel_$$"
    mkdir -p "$JOBDIR" 2>/dev/null

    local -a PIDS=() STATUS=()
    local i
    for i in "${!P_LINKS[@]}"; do STATUS[$i]="queued"; done

    local RUNNING=0 NEXT=0
    while :; do
        while [ "$RUNNING" -lt "$MAXP" ] && [ "$NEXT" -lt "$P_TOTAL" ]; do
            local idx="$NEXT"
            (
                do_download "${P_LINKS[$idx]}" "$CHOICE" "$(( idx + 1 ))" "$P_TOTAL" \
                    > "${JOBDIR}/${idx}.log" 2>&1 < /dev/null
                echo $? > "${JOBDIR}/${idx}.rc"
            ) &
            PIDS[$idx]=$!
            STATUS[$idx]="running"
            RUNNING=$(( RUNNING + 1 ))
            NEXT=$(( NEXT + 1 ))
        done

        clear 2>/dev/null
        local TW; TW=$(tput cols 2>/dev/null || echo 70)
        printf "\033[38;5;33m"; _repeat_char '━' "$TW"; printf "\033[0m\n"
        printf "  \033[1;97mPARALLEL DOWNLOADS\033[0m  \033[2m(%dx at once)\033[0m\n" "$MAXP"
        printf "\033[38;5;240m"; _repeat_char '─' "$TW"; printf "\033[0m\n"
        for i in "${!P_LINKS[@]}"; do
            local S="${STATUS[$i]}" DISP
            case "$S" in
                queued)  DISP="\033[2mqueued\033[0m" ;;
                running) DISP="\033[38;5;226mdownloading...\033[0m" ;;
                done)    DISP="\033[38;5;46mdone\033[0m" ;;
                failed)  DISP="\033[38;5;196mfailed\033[0m" ;;
            esac
            printf "  %2d. %-46s %b\n" "$(( i + 1 ))" "${P_LINKS[$i]:0:46}" "$DISP"
        done
        printf "\033[38;5;240m"; _repeat_char '─' "$TW"; printf "\033[0m\n"

        for i in "${!P_LINKS[@]}"; do
            [ "${STATUS[$i]}" = "running" ] || continue
            if ! kill -0 "${PIDS[$i]}" 2>/dev/null; then
                local RC=1
                [ -f "${JOBDIR}/${i}.rc" ] && RC=$(cat "${JOBDIR}/${i}.rc" 2>/dev/null)
                if [ "${RC:-1}" -eq 0 ]; then STATUS[$i]="done"; else STATUS[$i]="failed"; fi
                RUNNING=$(( RUNNING - 1 ))
            fi
        done

        [ "$NEXT" -ge "$P_TOTAL" ] && [ "$RUNNING" -eq 0 ] && break
        sleep 2
    done

    SUCCESS=0; FAIL_LIST=()
    for i in "${!P_LINKS[@]}"; do
        if [ "${STATUS[$i]}" = "done" ]; then
            SUCCESS=$(( SUCCESS + 1 ))
        else
            FAIL_LIST+=("${P_LINKS[$i]}")
        fi
    done
    rm -rf "$JOBDIR" 2>/dev/null
    return 0
}
_P_IDX=0
_P_PAUSED=0
_P_TITLE=""
_P_URL=""
_P_VOL=80
declare -a _P_URLS
declare -a _P_TITLES
_P_MSG=""
_P_REDRAW=1

_p_save_vol() {
    echo "{\"volume\":${_P_VOL}}" > "$PLAYER_SETTINGS"
}

_p_load_vol() {
    _P_VOL=$(python3 - "$PLAYER_SETTINGS" << 'PYEOF' 2>/dev/null
import json, sys
try:    print(json.load(open(sys.argv[1])).get('volume', 80))
except: print(80)
PYEOF
)
}

_p_load_queue() {
    local URL="$1"
    _P_URLS=(); _P_TITLES=()
    _P_IDX=0; _P_PID=""

    info_msg "Loading queue..."

    local CK_FLAGS=()
    [ -s "$COOKIE_FILE" ] && CK_FLAGS=(--cookies "$COOKIE_FILE")

    # FIX: Single yt-dlp call using both --print fields (saves one network round-trip)
    if echo "$URL" | grep -qE "list=|/channel/|/@|/c/"; then
        local TMP_COMBINED; TMP_COMBINED=$(mktemp "${TMP_DIR}/adm_qc_XXXXXX.txt")
        yt-dlp --flat-playlist -q --no-warnings \
            --print "%(webpage_url)s|||%(title)s" \
            "${CK_FLAGS[@]}" "$URL" > "$TMP_COMBINED" 2>/dev/null
        while IFS='|||' read -r U T; do
            [ -n "$U" ] && _P_URLS+=("$U")
            _P_TITLES+=("${T:-Track}")
        done < "$TMP_COMBINED"
        rm -f "$TMP_COMBINED"
    else
        _P_URLS=("$URL")
        local T
        T=$(yt-dlp --get-title -q --no-warnings --no-playlist "${CK_FLAGS[@]}" "$URL" 2>/dev/null)
        _P_TITLES+=("${T:-Track 1}")
    fi

    success_msg "${#_P_URLS[@]} song(s) loaded"
}

_p_play() {
    if [ -n "$_P_PID" ]; then
        kill "$_P_PID" 2>/dev/null
        wait "$_P_PID" 2>/dev/null
        _P_PID=""
    fi

    local TOTAL=${#_P_URLS[@]}
    if [ "$_P_IDX" -ge "$TOTAL" ] || [ "$_P_IDX" -lt 0 ]; then
        _P_MSG="End of queue"; _P_REDRAW=1; return 1
    fi

    _P_URL="${_P_URLS[$_P_IDX]}"
    _P_TITLE="${_P_TITLES[$_P_IDX]}"
    [ -z "$_P_TITLE" ] && _P_TITLE="Track $(( _P_IDX + 1 ))"

    info_msg "Buffering: ${_P_TITLE:0:45}..."

    local CK_FLAGS=()
    [ -s "$COOKIE_FILE" ] && CK_FLAGS=(--cookies "$COOKIE_FILE")
    local AUDIO_URL
    AUDIO_URL=$(yt-dlp -f "bestaudio/best" --get-url -q --no-warnings \
        --no-playlist "${CK_FLAGS[@]}" "$_P_URL" 2>/dev/null | head -1)

    local SKIP=0
    while [ -z "$AUDIO_URL" ] && [ "$_P_IDX" -lt "$TOTAL" ] && [ "$SKIP" -lt 5 ]; do
        warn_msg "Could not stream '${_P_TITLE:0:30}', skipping..."
        _P_IDX=$(( _P_IDX + 1 ))
        SKIP=$(( SKIP + 1 ))
        [ "$_P_IDX" -ge "$TOTAL" ] && break
        _P_URL="${_P_URLS[$_P_IDX]}"
        _P_TITLE="${_P_TITLES[$_P_IDX]}"
        AUDIO_URL=$(yt-dlp -f "bestaudio/best" --get-url -q --no-warnings \
            --no-playlist "${CK_FLAGS[@]}" "$_P_URL" 2>/dev/null | head -1)
    done

    [ -z "$AUDIO_URL" ] && _P_MSG="Could not play any tracks" && _P_REDRAW=1 && return 1

    local SOCK="${TMP_DIR}/mpv_adm.sock"
    rm -f "$SOCK"
    mpv --no-video --really-quiet \
        --volume="$_P_VOL" \
        --input-ipc-server="$SOCK" \
        "$AUDIO_URL" &
    _P_PID=$!
    _P_PAUSED=0
    _P_MSG=""
    _P_REDRAW=1
}

_p_toggle_pause() {
    local SOCK="${TMP_DIR}/mpv_adm.sock"
    if [ -S "$SOCK" ] && command -v socat &>/dev/null; then
        echo '{"command":["cycle","pause"]}' | socat - "$SOCK" 2>/dev/null
    elif [ -n "$_P_PID" ]; then
        [ "$_P_PAUSED" = "0" ] && kill -STOP "$_P_PID" 2>/dev/null \
                                || kill -CONT "$_P_PID" 2>/dev/null
    fi
    [ "$_P_PAUSED" = "0" ] && _P_PAUSED=1 || _P_PAUSED=0
    _P_REDRAW=1
}

_p_vol_change() {
    _P_VOL=$(( _P_VOL + $1 ))
    [ "$_P_VOL" -gt 130 ] && _P_VOL=130
    [ "$_P_VOL" -lt 0   ] && _P_VOL=0
    local SOCK="${TMP_DIR}/mpv_adm.sock"
    if [ -S "$SOCK" ] && command -v socat &>/dev/null; then
        echo "{\"command\":[\"set_property\",\"volume\",${_P_VOL}]}" | socat - "$SOCK" 2>/dev/null
    fi
    _p_save_vol
    _P_MSG="Volume: ${_P_VOL}%"
    _P_REDRAW=1
}

_p_draw() {
    [ "$_P_REDRAW" != "1" ] && return
    _P_REDRAW=0
    clear 2>/dev/null

    local TOTAL=${#_P_URLS[@]}
    local REM=$(( TOTAL - _P_IDX - 1 ))
    [ "$REM" -lt 0 ] && REM=0

    separator "="
    center_text "AUDIO PLAYER" "${BOLD}${C}"
    separator "="
    echo ""
    echo -e "  ${DIM}${C}Now Playing${N}"
    echo -e "  ${BOLD}${W}${_P_TITLE}${N}"
    echo ""

    if [ "$_P_PAUSED" = "1" ]; then
        center_text "||  PAUSED  ||" "${Y}"
    else
        center_text ">  PLAYING  <" "${G}"
    fi

    echo -e "\n  ${DIM}Vol: ${_P_VOL}%   Track: $((_P_IDX+1))/${TOTAL}   Remaining: ${REM}${N}"
    [ -n "$_P_MSG" ] && echo -e "\n  ${Y}${_P_MSG}${N}"

    if [ "$REM" -gt 0 ]; then
        echo ""
        line "-"
        echo -e "  ${DIM}${C}Up Next:${N}"
        local SHOW=3
        [ "$REM" -lt "$SHOW" ] && SHOW=$REM
        for i in $(seq 1 "$SHOW"); do
            local NI NT
            NI=$(( _P_IDX + i ))
            NT="${_P_TITLES[$NI]:-Track $((NI+1))}"
            echo -e "  ${DIM}  ${i}. ${NT:0:50}${N}"
        done
    fi

    echo ""
    line "-"
    echo -e "  ${Y}p${N}=pause  ${Y}n${N}=next  ${Y}b${N}=prev  ${Y}d${N}=download  ${Y}+${N}=vol+  ${Y}-${N}=vol-  ${Y}q${N}=quit"
    line "-"
    echo -e "  ${DIM}(single keypress — no Enter needed)${N}"
}

# ================================================================
# PLAYER DOWNLOAD
# FIX: Now embeds metadata + thumbnail, scans exact file
# ================================================================
_p_download() {
    [ -z "$_P_URL" ] && warn_msg "Nothing playing" && return

    local WAS="$_P_PAUSED"
    [ "$_P_PAUSED" = "0" ] && _p_toggle_pause

    clear 2>/dev/null
    separator "="
    center_text "DOWNLOADING" "${BOLD}${C}"
    separator "="
    info_msg "Song: ${_P_TITLE}"
    echo ""

    local PLATFORM SAVE_PATH
    PLATFORM=$(get_platform "$_P_URL")
    SAVE_PATH="${BASE_SAVE}/${PLATFORM}"
    mkdir -p "$SAVE_PATH"

    local CK_FLAGS=()
    [ -s "$COOKIE_FILE" ] && CK_FLAGS=(--cookies "$COOKIE_FILE")

    local SAVED_FILE=""
    SAVED_FILE=$(yt-dlp -f "bestaudio/best" \
        --extract-audio --audio-format mp3 --audio-quality 0 \
        --embed-thumbnail \
        --add-metadata --embed-metadata \
        --no-playlist \
        --print "after_move:filepath" \
        --output "$SAVE_PATH/$(_get_filename_template)" \
        "${CK_FLAGS[@]}" "$_P_URL" 2>&1 | grep "^/" | tail -1)

    if [ $? -eq 0 ]; then
        if [ "$OS_TYPE" = "android" ]; then
            if [ -n "$SAVED_FILE" ] && [ -f "$SAVED_FILE" ]; then
                trigger_media_scan "$SAVED_FILE"
            else
                trigger_media_scan "$SAVE_PATH"
            fi
        fi
        success_msg "Saved to: ${SAVE_PATH}"
        [ -n "$SAVED_FILE" ] && dim_msg "File: $(basename "$SAVED_FILE")"
    else
        error_msg "Download failed"
        cookie_hint "$PLATFORM"
    fi

    echo ""
    echo -ne "  ${DIM}Press Enter to return...${N}"; read -r
    [ "$WAS" = "0" ] && _p_toggle_pause
    _P_REDRAW=1
}

audio_player_page() {
    separator "="
    center_text "AUDIO PLAYER" "${BOLD}${C}"
    separator "="
    echo ""
    echo -e "  ${DIM}Enter a song, playlist, or mix URL (Enter=back)${N}"
    echo -ne "  ${C}>${N} "
    read -r PURL
    [ -z "$PURL" ] && return
    [[ ! "$PURL" == http* ]] && error_msg "Invalid URL" && sleep 1 && return

    command -v mpv &>/dev/null || { warn_msg "Installing mpv..."; auto_install mpv; }
    command -v mpv &>/dev/null || { error_msg "mpv install failed"; sleep 2; return; }

    _p_load_vol
    _p_load_queue "$PURL"
    [ "${#_P_URLS[@]}" -eq 0 ] && error_msg "No songs found" && sleep 2 && return

    _p_play || { error_msg "Could not start playback"; sleep 2; return; }

    while true; do
        if [ -n "$_P_PID" ] && ! kill -0 "$_P_PID" 2>/dev/null; then
            _P_IDX=$(( _P_IDX + 1 ))
            if [ "$_P_IDX" -ge "${#_P_URLS[@]}" ]; then
                _P_PID=""
                _P_TITLE="-- Queue finished --"
                _P_PAUSED=0
                _P_REDRAW=1
            else
                _p_play
            fi
        fi

        _p_draw

        # Read single keypress — no Enter needed
        CMD=""
        IFS= read -r -s -n1 -t 2 CMD
        local IRET=$?

        # Timeout (no key pressed) — just loop to check track status
        [ "$IRET" -gt 128 ] && continue
        [ -z "$CMD" ] && continue

        # Strip carriage return
        CMD="${CMD%$'\r'}"
        [ -z "$CMD" ] && continue

        case "$CMD" in
            p|P) _p_toggle_pause ;;
            n|N)
                _P_IDX=$(( _P_IDX + 1 ))
                if [ "$_P_IDX" -ge "${#_P_URLS[@]}" ]; then
                    _P_IDX=$(( ${#_P_URLS[@]} - 1 ))
                    _P_MSG="Last song"; _P_REDRAW=1
                else
                    _p_play
                fi ;;
            b|B)
                [ "$_P_IDX" -gt 0 ] && _P_IDX=$(( _P_IDX - 1 ))
                _p_play ;;
            d|D) _p_download ;;
            +|=) _p_vol_change 10 ;;
            -|_) _p_vol_change -10 ;;
            q|Q)
                [ -n "$_P_PID" ] && kill "$_P_PID" 2>/dev/null && wait "$_P_PID" 2>/dev/null
                rm -f "${TMP_DIR}/mpv_adm.sock"
                _P_PID=""
                _P_URLS=()
                _P_TITLES=()
                _p_save_vol
                break ;;
            *) ;;
        esac
    done

    # FIX: explicit clear + draw_banner so banner always redraws cleanly after player exits
    draw_banner
}

# ================================================================
# MAIN LOOP
# ================================================================
main_loop() {
    local CHOICE TOTAL SUCCESS IS_PLAYLIST
    local -a LINKS FAIL_LIST
    check_and_fix_all
    auto_update_ytdlp
    draw_banner
    ytdlp_version_check

    # Speed buffer reset per session
    _SPEED_BUF=()
    _SPEED_IDX=0

    while true; do
        echo ""
        echo -e "${DIM}${C}  - - - - - - - - - - - - - - - - - - - - - - - -${N}"
        center_text "Enter link(s)" "${BOLD}${W}"
        echo -e "${DIM}  one per line  --  blank line to start${N}"

        # Clipboard auto-detect
        local _CLIP; _CLIP=$(check_clipboard 2>/dev/null)
        local _CLIP_ALL; _CLIP_ALL=$(check_clipboard_all 2>/dev/null)
        local _CLIP_COUNT; _CLIP_COUNT=$(echo "$_CLIP_ALL" | grep -c "http" 2>/dev/null || echo 0)

        if [ -n "$_CLIP_ALL" ] && [ "$_CLIP_COUNT" -gt 0 ]; then
            if [ "$_CLIP_COUNT" -eq 1 ]; then
                echo -e "${DIM}${Y}  📋 Clipboard: ${_CLIP:0:55}${N}"
                echo -e "${DIM}  c = paste this URL${N}"
            else
                echo -e "${DIM}${Y}  📋 Clipboard: ${_CLIP_COUNT} URL found${N}"
                echo -e "${DIM}  c = paste first URL   v = paste all ${_CLIP_COUNT} URLs${N}"
            fi
        fi

        echo -e "${DIM}${C}  - - - - - - - - - - - - - - - - - - - - - - - -${N}"

        LINKS=()
        while true; do
            echo -ne "  ${C}>${N} "
            read -r LINE
            if [ -z "$LINE" ]; then
                [ ${#LINKS[@]} -gt 0 ] && break
                echo -e "${DIM}  Type a link, or:  c=clipboard  v=all URLs  play  st  cfg  log  upd  stor  doc  yts  file  qr  sub  sch  bak  fix  q${N}"
                continue
            fi
            case "$LINE" in
                q)
                    separator "="
                    center_text "Goodbye!" "${G}"
                    separator "="
                    [ "$OS_TYPE" = "linux" ] && tmux kill-session -t "$TMUX_SESSION" 2>/dev/null
                    exit 0 ;;
                st)   show_stats;         draw_banner ;;
                hist) show_history;       draw_banner ;;
                cfg)  show_settings;      draw_banner ;;
                log)  show_log;           draw_banner ;;
                upd)  self_update; echo -ne "  ${DIM}Press Enter...${N}"; read -r; draw_banner ;;
                stor) show_storage_manager; draw_banner ;;
                doc)  run_doctor;         draw_banner ;;
                qr)   share_file_qr;      draw_banner ;;
                sub)  subscriptions_menu; draw_banner ;;
                sch)  schedule_downloads; draw_banner ;;
                bak)  backup_settings; echo -ne "  ${DIM}Press Enter...${N}"; read -r; draw_banner ;;
                yts)
                    run_youtube_search_pick
                    if [ -n "$_YTS_PICKED_URL" ]; then
                        LINKS+=("$_YTS_PICKED_URL")
                        success_msg "Added: ${_YTS_PICKED_URL}"
                    fi
                    draw_banner ;;
                file)
                    echo -ne "  ${W}Path to .txt file${N} (one link per line): "
                    read -r _FPATH
                    if [ -f "$_FPATH" ]; then
                        local _FCOUNT=0
                        while IFS= read -r _FL || [ -n "$_FL" ]; do
                            _FL="$(echo "$_FL" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
                            [ -z "$_FL" ] && continue
                            [[ "$_FL" == \#* ]] && continue
                            LINKS+=("$_FL")
                            _FCOUNT=$(( _FCOUNT + 1 ))
                        done < "$_FPATH"
                        success_msg "${_FCOUNT} link(s) imported from file"
                        log_msg "INFO" "Imported ${_FCOUNT} links from ${_FPATH}"
                    else
                        error_msg "File not found: ${_FPATH}"
                    fi ;;
                play) audio_player_page;  draw_banner; continue 2 ;;
                spd)  run_speed_test;     draw_banner ;;
                fix)  fix_extensions;     draw_banner ;;
                c|C)
                    local _CL; _CL=$(check_clipboard 2>/dev/null)
                    if [ -n "$_CL" ]; then
                        LINKS+=("$_CL")
                        success_msg "Added from clipboard: ${_CL:0:50}"
                    else
                        warn_msg "No URL found in clipboard."
                    fi ;;
                v|V)
                    local _ALL_URLS; _ALL_URLS=$(check_clipboard_all 2>/dev/null)
                    if [ -n "$_ALL_URLS" ]; then
                        local _COUNT=0
                        while IFS= read -r _U; do
                            [ -z "$_U" ] && continue
                            LINKS+=("$_U")
                            dim_msg "${_U:0:55}"
                            _COUNT=$(( _COUNT + 1 ))
                        done <<< "$_ALL_URLS"
                        success_msg "${_COUNT} URL(s) added from clipboard"
                    else
                        warn_msg "No URLs found in clipboard."
                    fi ;;
                *)
                    for PART in $(echo "$LINE" | sed -E 's/,(https?:\/\/)/ \1/g'); do
                        [[ "$PART" == http* ]] && LINKS+=("$PART")
                    done ;;
            esac
        done

        # ── Classify: video/social (yt-dlp) vs plain file (direct engine) ──
        FILE_NAME_OVERRIDE=""
        local _ANY_MEDIA=0 _ANY_FILE=0 _L
        for _L in "${LINKS[@]}"; do
            _classify_url "$_L"
            if [ "$CLS_KIND" = "file" ]; then _ANY_FILE=1; else _ANY_MEDIA=1; fi
        done
        # Unknown web page with no video in it: offer the files it links to
        if [ ${#LINKS[@]} -eq 1 ] && [ "$CLS_KIND" = "page" ]; then
            if _page_flow "${LINKS[0]}"; then
                LINKS=("${PAGE_PICKED[@]}")
                _ANY_MEDIA=0; _ANY_FILE=1
            fi
        fi

        # Playlist detect — only for a single video/social link
        PLAYLIST_ITEMS=""
        IS_PLAYLIST=0
        _HLS_CACHE_URL=""   # Reset HLS cache for new URL
        if [ ${#LINKS[@]} -eq 1 ] && [ "$_ANY_MEDIA" -eq 1 ]; then
            if [[ "${LINKS[0]}" == *"list="* ]] || [[ "${LINKS[0]}" == *"/channel/"* ]] || \
               [[ "${LINKS[0]}" == *"/c/"*  ]] || [[ "${LINKS[0]}" == *"/@"* ]]; then
                select_playlist_items "${LINKS[0]}"
                IS_PLAYLIST=1
            fi
        fi

        if [ ${#LINKS[@]} -eq 1 ]; then
            if [ "$_ANY_MEDIA" -eq 0 ]; then
                _show_file_card "${LINKS[0]}" || continue
            elif [ "$IS_PLAYLIST" -eq 0 ]; then
                fetch_and_show "${LINKS[0]}"
                local _FS_RET=$?
                [ "$_FS_RET" -eq 1 ] && continue
            else
                show_menu_simple
            fi
        else
            info_msg "${#LINKS[@]} links queued"
            if [ "$_ANY_FILE" -eq 1 ] && [ "$_ANY_MEDIA" -eq 1 ]; then
                dim_msg "Files download as they are; the quality below applies to video links."
            elif [ "$_ANY_FILE" -eq 1 ]; then
                dim_msg "All links are plain files — downloaded as they are."
            fi
            [ "$_ANY_MEDIA" -eq 1 ] && show_menu_simple
        fi

        if [ "$_ANY_MEDIA" -eq 1 ]; then
            echo ""
            echo -ne "  ${BOLD}${W}Quality${N} ${DIM}(1-7 / Enter=cancel)${N}: "
            read -r CHOICE
            [ "$CHOICE" = "q" ] && exit 0
            [ -z "$CHOICE" ] && continue
            [[ ! "$CHOICE" =~ ^[1-7]$ ]] && error_msg "Invalid choice" && continue
        else
            CHOICE="F"      # files only: no quality to choose
        fi

        if ! wifi_gate_check; then
            continue
        fi
        if [ "$(get_setting data_saver)" = "true" ] && [[ "$CHOICE" =~ ^[123]$ ]]; then
            warn_msg "Data Saver is ON — downloading at 480p instead."
            CHOICE="5"
        fi

        TOTAL=${#LINKS[@]}

        # ── Video Trim (single link only) ──────────────────────
        TRIM_SECTION=""
        if [ "$TOTAL" -eq 1 ] && [ "$IS_PLAYLIST" -eq 0 ] && [ "$_ANY_MEDIA" -eq 1 ]; then
            echo -ne "  ${DIM}Trim to a time range instead of full video? [y/N]: ${N}"
            read -r _TRIM_ANS
            if [[ "$_TRIM_ANS" =~ ^[Yy]$ ]]; then
                echo -ne "  ${W}Start${N} (mm:ss, blank=0:00): "
                read -r _T_START
                echo -ne "  ${W}End${N}   (mm:ss, blank=end of video): "
                read -r _T_END
                [ -z "$_T_START" ] && _T_START="0"
                if [ -n "$_T_END" ]; then
                    TRIM_SECTION="*${_T_START}-${_T_END}"
                else
                    TRIM_SECTION="*${_T_START}-inf"
                fi
                info_msg "Will trim: ${_T_START} → ${_T_END:-end}"
            fi
        fi

        # ── Batch status tracking ──────────────────────────────
        local -a BATCH_TITLES BATCH_STATUS BATCH_PCT
        for i in "${!LINKS[@]}"; do
            BATCH_TITLES+=("${LINKS[$i]}")
            BATCH_STATUS+=("pending")
            BATCH_PCT+=("0")
        done

        run_parallel_batch "$CHOICE" "${LINKS[@]}"
        if [ $? -eq 2 ]; then
        SUCCESS=0; FAIL_LIST=()
        for i in "${!LINKS[@]}"; do
            local CURR
            CURR=$(( i + 1 ))

            # Show batch list before each download (if >1 link)
            if [ "$TOTAL" -gt 1 ]; then
                local BATCH_ARGS=()
                for j in "${!LINKS[@]}"; do
                    BATCH_ARGS+=("${BATCH_TITLES[$j]}|${BATCH_STATUS[$j]}|${BATCH_PCT[$j]}")
                done
                _draw_batch_screen "$CURR" "$TOTAL" "${BATCH_ARGS[@]}"
                sleep 1
            fi

            BATCH_STATUS[$i]="downloading"
            [ "$i" -gt 0 ] && PLAYLIST_ITEMS=""
            do_download "${LINKS[$i]}" "$CHOICE" "$CURR" "$TOTAL"
            if [ $? -eq 0 ]; then
                SUCCESS=$(( SUCCESS + 1 ))
                BATCH_STATUS[$i]="done"
                BATCH_PCT[$i]="100"
            else
                FAIL_LIST+=("${LINKS[$i]}")
                BATCH_STATUS[$i]="failed"
            fi
        done
        fi

        # ── Final summary screen ───────────────────────────────
        clear 2>/dev/null
        local TW; TW=$(tput cols 2>/dev/null || echo 60)
        local SUM_CLR="46"
        [ "$SUCCESS" -lt "$TOTAL" ] && SUM_CLR="208"
        [ "$SUCCESS" -eq 0 ] && SUM_CLR="196"

        printf "\033[38;5;${SUM_CLR}m"
        printf '%*s' "$TW" '' | tr ' ' '━'
        printf "\033[0m\n"
        printf "\n  \033[1;37mALL DONE\033[0m\n\n"
        printf "  \033[38;5;46m✓ Success  \033[0m\033[1;37m%d / %d\033[0m\n" "$SUCCESS" "$TOTAL"
        [ ${#FAIL_LIST[@]} -gt 0 ] &&             printf "  \033[38;5;196m✗ Failed   \033[0m\033[1;37m%d\033[0m\n" "${#FAIL_LIST[@]}"
        local _SAVED_NOTE="${BASE_SAVE}/[Platform]/"
        if [ "$_ANY_MEDIA" -eq 0 ]; then
            case "$(get_setting file_layout)" in
                site) _SAVED_NOTE="${BASE_SAVE}/[Site]/" ;;
                flat) _SAVED_NOTE="${BASE_SAVE}/Files/" ;;
                *)    _SAVED_NOTE="${BASE_SAVE}/Files/[Type]/" ;;
            esac
        elif [ "$_ANY_FILE" -eq 1 ]; then
            _SAVED_NOTE="${BASE_SAVE}/[Platform] + Files/"
        fi
        printf "  \033[38;5;244mSaved in  \033[0m\033[1;37m%s\033[0m\n\n" "$_SAVED_NOTE"
        printf "\033[38;5;${SUM_CLR}m"
        printf '%*s' "$TW" '' | tr ' ' '━'
        printf "\033[0m\n"

        # ── Retry-failed-only ───────────────────────────────────
        if [ ${#FAIL_LIST[@]} -gt 0 ]; then
            echo -ne "\n  ${Y}Retry the ${#FAIL_LIST[@]} failed link(s)? [y/N]: ${N}"
            read -r _RETRY_ANS
            if [[ "$_RETRY_ANS" =~ ^[Yy]$ ]]; then
                local -a _RTY_LINKS=("${FAIL_LIST[@]}")
                local _RTY_TOTAL=${#_RTY_LINKS[@]}
                local -a _RTY_TITLES=() _RTY_STATUS=() _RTY_PCT=()
                for i in "${!_RTY_LINKS[@]}"; do
                    _RTY_TITLES+=("${_RTY_LINKS[$i]}")
                    _RTY_STATUS+=("pending")
                    _RTY_PCT+=("0")
                done
                local _RTY_SUCCESS=0
                local -a _RTY_STILL_FAILED=()
                for i in "${!_RTY_LINKS[@]}"; do
                    local _RTY_CURR=$(( i + 1 ))
                    if [ "$_RTY_TOTAL" -gt 1 ]; then
                        local _RTY_ARGS=()
                        for j in "${!_RTY_LINKS[@]}"; do
                            _RTY_ARGS+=("${_RTY_TITLES[$j]}|${_RTY_STATUS[$j]}|${_RTY_PCT[$j]}")
                        done
                        _draw_batch_screen "$_RTY_CURR" "$_RTY_TOTAL" "${_RTY_ARGS[@]}"
                        sleep 1
                    fi
                    _RTY_STATUS[$i]="downloading"
                    [ "$i" -gt 0 ] && PLAYLIST_ITEMS=""
                    do_download "${_RTY_LINKS[$i]}" "$CHOICE" "$_RTY_CURR" "$_RTY_TOTAL"
                    if [ $? -eq 0 ]; then
                        _RTY_SUCCESS=$(( _RTY_SUCCESS + 1 ))
                        _RTY_STATUS[$i]="done"; _RTY_PCT[$i]="100"
                    else
                        _RTY_STILL_FAILED+=("${_RTY_LINKS[$i]}")
                        _RTY_STATUS[$i]="failed"
                    fi
                done
                log_msg "INFO" "Retry-failed pass: ${_RTY_SUCCESS}/${_RTY_TOTAL} recovered"
                if [ ${#_RTY_STILL_FAILED[@]} -eq 0 ]; then
                    success_msg "All retried downloads succeeded!"
                else
                    warn_msg "${#_RTY_STILL_FAILED[@]} link(s) still failing after retry."
                fi
                sleep 2
            fi
        fi

        echo -ne "\n  \033[2mPress Enter to continue...\033[0m"; read -r
    done
}

# ================================================================
# ENTRY POINT
# ================================================================
case "${1:-}" in
    --header-loop) header_loop ;;
    --main)        main_loop ;;
    --update|update)       self_update ;;
    --uninstall|uninstall) self_uninstall ;;
    --version|version)     echo "${APP_NAME} ${VERSION}" ;;
    --doctor|doctor)       run_doctor ;;
    --storage|storage)     show_storage_manager ;;
    --sync|sync)           sub_sync ;;
    --run-file)            run_file_batch "${2:-}" "${3:-5}" ;;
    --backup|backup)       backup_settings ;;
    --restore|restore)     restore_settings ;;
    *)
        check_app_lock
        if [ "$OS_TYPE" = "linux" ]; then
            launch_in_tmux
            main_loop
        else
            main_loop
        fi ;;
esac
