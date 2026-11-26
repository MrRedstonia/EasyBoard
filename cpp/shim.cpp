#include <QApplication>
#include <QGuiApplication>
#include <QIcon>
#include <QTimer>
#include <QQuickWindow>
#include <QQuickItem>
#include <QMouseEvent>
#include <QDateTime>
#include <QCursor>
#include <QPixmap>
#include <QPainter>
#include <QString>
#include <QSettings>
#include <QStyleHints>
#include <QPalette>
#include <QWindow>
#include <QQuickStyle>
#include <QByteArray>
#include <QClipboard>
#include <QMimeData>
#include <QUrl>
#include <QFileInfo>
#include <QFileIconProvider>
#include <cstring>
#include <QImage>
#include <QImageReader>
#include <QDir>
#include <QFile>
#ifdef Q_OS_WIN
#include <windows.h>
#include <objbase.h>
#include <wincodec.h>
#include <dwmapi.h>
#pragma comment(lib, "dwmapi.lib")
#pragma comment(lib, "windowscodecs.lib")
#pragma comment(lib, "ole32.lib")
#endif
#ifdef Q_OS_MACOS
#include <ImageIO/ImageIO.h>
#endif

// Qt.labs.platform falls back to QWidget-based menus / tray icons on some Linux
// desktops, which requires a real QApplication (not just QGuiApplication).
static int g_argc = 1;
static char g_arg0[] = "easyboard";
static char *g_argv[] = {g_arg0, nullptr};
static QApplication *g_app = nullptr;

// Clicking anywhere outside a text field takes the keyboard focus away from it.
class FocusFilter : public QObject {
public:
    using QObject::QObject;
    bool eventFilter(QObject *o, QEvent *e) override {
        if (e->type() != QEvent::MouseButtonPress)
            return false;
        auto *w = qobject_cast<QQuickWindow *>(o);
        if (!w)
            return false;
        QQuickItem *f = w->activeFocusItem();
        if (!f || f->metaObject()->indexOfProperty("cursorPosition") < 0)
            return false;
        const auto *me = static_cast<QMouseEvent *>(e);
        if (!f->contains(f->mapFromScene(me->position()))) {
            f->setFocus(false, Qt::MouseFocusReason);
            w->contentItem()->forceActiveFocus(Qt::MouseFocusReason);
        }
        return false;
    }
};

extern "C" void easyboard_create_app() {
    // Rust's std::env::set_var does not reach the C runtime copy Qt reads on
    // Windows, so the style and platform options are set here instead.
    if (!qEnvironmentVariableIsSet("QT_QUICK_CONTROLS_STYLE"))
        qputenv("QT_QUICK_CONTROLS_STYLE", "Fusion");
#ifdef _WIN32
    if (!qEnvironmentVariableIsSet("QT_QPA_PLATFORM"))
        qputenv("QT_QPA_PLATFORM", "windows:darkmode=2");
    // Windows usually runs at 125-150% display scaling, which makes the app look noticeably bigger than
    // on Linux: draw it at 90% of that (unless the user set a scale factor themselves).
    if (!qEnvironmentVariableIsSet("QT_SCALE_FACTOR"))
        qputenv("QT_SCALE_FACTOR", "0.9");
#endif
    if (!qEnvironmentVariableIsSet("QT_LOGGING_RULES"))
        qputenv("QT_LOGGING_RULES", "qt.qpa.wayland.warning=false");
    if (!g_app)
        g_app = new QApplication(g_argc, g_argv);
    QQuickStyle::setStyle(QStringLiteral("Fusion"));
    g_app->installEventFilter(new FocusFilter(g_app));
}

// First local file on the clipboard (e.g. copied in a file manager): UTF-8 path, 0 if there is none.
extern "C" int easyboard_clipboard_file(char *buf, int cap) {
    const QMimeData *m = QGuiApplication::clipboard()->mimeData();
    if (!m || !m->hasUrls())
        return 0;
    const auto urls = m->urls();
    for (const QUrl &u : urls) {
        if (!u.isLocalFile())
            continue;
        const QByteArray b = u.toLocalFile().toUtf8();
        if (b.size() < cap) {
            std::memcpy(buf, b.constData(), static_cast<size_t>(b.size()));
            return b.size();
        }
    }
    return 0;
}

extern "C" void easyboard_clipboard_clear() {
    QGuiApplication::clipboard()->clear();
}

extern "C" int easyboard_exec() {
    return QApplication::exec();
}

extern "C" void easyboard_set_window_icon(const char *path) {
    QGuiApplication::setWindowIcon(QIcon(QString::fromUtf8(path)));
}

extern "C" void easyboard_set_window_icon_data(const unsigned char *data, unsigned long len) {
    QPixmap src;
    if (!src.loadFromData(data, static_cast<uint>(len)) || src.isNull())
        return;
#ifdef Q_OS_MACOS
    // The Dock shows the picture edge to edge, so it needs the same transparent border Apple's own
    // icons have (the artwork fills roughly 80% of the square).
    {
        const int side = qMax(src.width(), src.height());
        QPixmap padded(side, side);
        padded.fill(Qt::transparent);
        const QPixmap inner = src.scaled(int(side * 0.80), int(side * 0.80), Qt::KeepAspectRatio, Qt::SmoothTransformation);
        QPainter p(&padded);
        p.drawPixmap((side - inner.width()) / 2, (side - inner.height()) / 2, inner);
        p.end();
        src = padded;
    }
#endif
    QIcon icon;
    const int sizes[] = {16, 20, 24, 32, 40, 48, 64, 128, 256};
    for (int s : sizes)
        icon.addPixmap(src.scaled(s, s, Qt::KeepAspectRatio, Qt::SmoothTransformation));
    QGuiApplication::setWindowIcon(icon);
}

extern "C" void easyboard_cursor_pos(int *x, int *y) {
    const QPoint p = QCursor::pos();
    *x = p.x();
    *y = p.y();
}

extern "C" void easyboard_set_quit_on_last_window_closed(bool on) {
    QGuiApplication::setQuitOnLastWindowClosed(on);
}

extern "C" void easyboard_set_app_names() {
    QGuiApplication::setApplicationName(QStringLiteral("EasyBoard"));
    QGuiApplication::setOrganizationName(QStringLiteral("MrRedstonia"));
    QGuiApplication::setApplicationVersion(QStringLiteral("0.2.5"));
    QGuiApplication::setDesktopFileName(QStringLiteral("easyboard"));
}

// ---------------------------------------------------------------------------------------------
// Theme handling. Qt's own dark/light switching is unreliable on Windows, and the user can force
// light/dark in Settings, so EasyBoard builds the palette itself whenever it is needed:
//   Windows: always (system scheme + accent color from the registry)
//   others : only while a light/dark override is set; "follow system" restores the original palette.
// ---------------------------------------------------------------------------------------------
static int g_override = 0;          // 0 = follow system, 1 = dark, 2 = light
static QPalette g_systemPalette;    // the palette the platform gave us at start-up

static bool eb_dark_effective() {
    if (g_override != 0)
        return g_override == 1;
#if QT_VERSION >= QT_VERSION_CHECK(6, 5, 0)
    return QGuiApplication::styleHints()->colorScheme() == Qt::ColorScheme::Dark;
#else
    return false;
#endif
}

static QColor eb_accent() {
#ifdef Q_OS_WIN
    // The user's accent color, stored as 0xAABBGGRR.
    QSettings reg(QStringLiteral("HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Accent"),
                  QSettings::NativeFormat);
    bool ok = false;
    const uint v = reg.value(QStringLiteral("AccentColorMenu")).toUInt(&ok);
    QColor c = (ok && v != 0) ? QColor(int(v & 0xff), int((v >> 8) & 0xff), int((v >> 16) & 0xff))
                              : QColor(0x00, 0x78, 0xd4);
    // The registry value looks more saturated on screen than the accent Windows itself draws:
    // a little less saturation and more lightness.
    float h, sa, l, al;
    c.getHslF(&h, &sa, &l, &al);
    return QColor::fromHslF(h < 0 ? 0 : h, sa * 0.88f, l + (1.0f - l) * 0.16f, al);
#else
    return g_systemPalette.color(QPalette::Highlight);
#endif
}

static void eb_apply_titlebars() {
#ifdef Q_OS_WIN
    const BOOL dark = eb_dark_effective() ? TRUE : FALSE;
    for (QWindow *w : QGuiApplication::allWindows()) {
        HWND hwnd = reinterpret_cast<HWND>(w->winId());
        if (!hwnd)
            continue;
        DwmSetWindowAttribute(hwnd, 20 /* DWMWA_USE_IMMERSIVE_DARK_MODE */, &dark, sizeof(dark));
    }
#endif
}

static void eb_apply_theme() {
#ifndef Q_OS_WIN
    // Other platforms: the QML layer paints the neutral palette; only the color scheme is forced.
    return;
#endif
    const bool dark = eb_dark_effective();
    const QColor ac = eb_accent();
    QPalette p;
    auto all = [&](QPalette::ColorRole r, const QColor &c) { p.setColor(QPalette::All, r, c); };
    auto dis = [&](QPalette::ColorRole r, const QColor &c) { p.setColor(QPalette::Disabled, r, c); };
    if (dark) {
        all(QPalette::Window, QColor("#202020"));
        all(QPalette::WindowText, QColor("#ffffff"));
        all(QPalette::Base, QColor("#2b2b2b"));
        all(QPalette::AlternateBase, QColor("#323232"));
        all(QPalette::Text, QColor("#ffffff"));
        all(QPalette::Button, QColor("#2d2d2d"));
        all(QPalette::ButtonText, QColor("#ffffff"));
        all(QPalette::BrightText, QColor("#ffffff"));
        all(QPalette::Light, QColor("#404040"));
        all(QPalette::Midlight, QColor("#353535"));
        all(QPalette::Mid, QColor("#4a4a4a"));
        all(QPalette::Dark, QColor("#151515"));
        all(QPalette::Shadow, QColor("#000000"));
        all(QPalette::ToolTipBase, QColor("#2b2b2b"));
        all(QPalette::ToolTipText, QColor("#ffffff"));
        all(QPalette::PlaceholderText, QColor(255, 255, 255, 110));
        dis(QPalette::WindowText, QColor("#808080"));
        dis(QPalette::Text, QColor("#808080"));
        dis(QPalette::ButtonText, QColor("#808080"));
    } else {
        all(QPalette::Window, QColor("#f3f3f3"));
        all(QPalette::WindowText, QColor("#1b1b1b"));
        all(QPalette::Base, QColor("#ffffff"));
        all(QPalette::AlternateBase, QColor("#f7f7f7"));
        all(QPalette::Text, QColor("#1b1b1b"));
        all(QPalette::Button, QColor("#fbfbfb"));
        all(QPalette::ButtonText, QColor("#1b1b1b"));
        all(QPalette::BrightText, QColor("#ffffff"));
        all(QPalette::Light, QColor("#ffffff"));
        all(QPalette::Midlight, QColor("#ececec"));
        all(QPalette::Mid, QColor("#c9c9c9"));
        all(QPalette::Dark, QColor("#a0a0a0"));
        all(QPalette::Shadow, QColor("#707070"));
        all(QPalette::ToolTipBase, QColor("#ffffff"));
        all(QPalette::ToolTipText, QColor("#1b1b1b"));
        all(QPalette::PlaceholderText, QColor(0, 0, 0, 120));
        dis(QPalette::WindowText, QColor("#9a9a9a"));
        dis(QPalette::Text, QColor("#9a9a9a"));
        dis(QPalette::ButtonText, QColor("#9a9a9a"));
    }
    const QColor onAccent = ac.lightnessF() > 0.7 ? QColor("#000000") : QColor("#ffffff");
    all(QPalette::Highlight, ac);
    all(QPalette::HighlightedText, onAccent);
    all(QPalette::Link, ac.lighter(dark ? 140 : 100));
    all(QPalette::LinkVisited, ac);
#if QT_VERSION >= QT_VERSION_CHECK(6, 6, 0)
    all(QPalette::Accent, ac);
#endif
    QGuiApplication::setPalette(p);
    eb_apply_titlebars();
}

// The real system dark/light state, independent of EasyBoard's own override
// (Windows: the taskbar theme, which is what the tray icon sits on).
extern "C" bool easyboard_system_dark() {
    static qint64 last = 0;
    static bool cached = true;
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    if (now - last < 1000)
        return cached;
    last = now;
#ifdef Q_OS_WIN
    QSettings reg(QStringLiteral("HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"),
                  QSettings::NativeFormat);
    cached = reg.value(QStringLiteral("SystemUsesLightTheme"), 0).toInt() == 0;
#else
    if (g_override == 0) {
#if QT_VERSION >= QT_VERSION_CHECK(6, 5, 0)
        cached = QGuiApplication::styleHints()->colorScheme() == Qt::ColorScheme::Dark;
#endif
    } else {
        cached = g_systemPalette.color(QPalette::Window).lightness() < 128;
    }
#endif
    return cached;
}

extern "C" void easyboard_set_theme(bool follow, bool dark) {
    g_override = follow ? 0 : (dark ? 1 : 2);
#if QT_VERSION >= QT_VERSION_CHECK(6, 8, 0)
    QGuiApplication::styleHints()->setColorScheme(
        follow ? Qt::ColorScheme::Unknown : (dark ? Qt::ColorScheme::Dark : Qt::ColorScheme::Light));
#endif
    eb_apply_theme();
}

extern "C" void easyboard_install_theme() {
    g_systemPalette = QGuiApplication::palette();
    eb_apply_theme();
#ifdef Q_OS_WIN
#if QT_VERSION >= QT_VERSION_CHECK(6, 5, 0)
    QObject::connect(QGuiApplication::styleHints(), &QStyleHints::colorSchemeChanged,
                     QGuiApplication::instance(), [] { eb_apply_theme(); });
#endif
    // Windows has no Qt signal for accent color changes, so check the registry once a second
    // (a single cheap read) and re-apply the palette when it changed, focused or not.
    static QColor last = eb_accent();
    auto *timer = new QTimer(qGuiApp);
    QObject::connect(timer, &QTimer::timeout, qGuiApp, [] {
        const QColor now = eb_accent();
        if (now != last) { last = now; eb_apply_theme(); }
    });
    timer->start(1000);
    // New windows get the right title bar as soon as they receive focus.
    QObject::connect(qGuiApp, &QGuiApplication::focusWindowChanged, qGuiApp,
                     [](QWindow *) { eb_apply_titlebars(); });
#endif
}

extern "C" void easyboard_apply_titlebars() {
    eb_apply_titlebars();
}

// App routing: renders an app's icon to a PNG at `out_path`. `spec` is "theme:<icon name>"
// (Linux icon theme) or "file:<path>" (an icon file, a Windows .exe or a macOS .app bundle).
// Must run on the GUI thread. Returns false when there is no icon.
// Windows hands out a program's icon on a 256 px canvas even when the program only has a small one;
// the small icon then sits in the top-left corner of an otherwise empty picture. Cut such a picture
// down to the icon itself.
static QImage eb_trim_corner_icon(const QImage &src) {
    const QImage img = src.convertToFormat(QImage::Format_ARGB32);
    int maxX = -1, maxY = -1;
    for (int y = 0; y < img.height(); ++y) {
        const QRgb *row = reinterpret_cast<const QRgb *>(img.constScanLine(y));
        for (int x = 0; x < img.width(); ++x)
            if (qAlpha(row[x]) > 8) {
                maxX = qMax(maxX, x);
                maxY = qMax(maxY, y);
            }
    }
    if (maxX < 0)
        return img;
    const int used = qMax(maxX, maxY) + 1;
    for (int size : {16, 20, 24, 32, 40, 48, 64, 96, 128}) {
        if (size >= img.width() || size >= img.height())
            break;
        if (used <= size)
            return img.copy(0, 0, size, size);
    }
    return img;
}

extern "C" bool easyboard_app_icon(const char *spec, const char *out_path) {
    const QString s = QString::fromUtf8(spec);
    QIcon icon;
    if (s.startsWith(QLatin1String("theme:"))) {
        const QString name = s.mid(6);
        icon = QIcon::fromTheme(name);
        if (icon.isNull() && name != name.toLower())
            icon = QIcon::fromTheme(name.toLower());
        if (icon.isNull()) {
            // icons that are only in /usr/share/pixmaps
            for (const char *ext : {".png", ".svg", ".xpm"}) {
                const QString p = QStringLiteral("/usr/share/pixmaps/") + name + QLatin1String(ext);
                if (QFileInfo::exists(p)) { icon = QIcon(p); break; }
            }
        }
    } else if (s.startsWith(QLatin1String("file:"))) {
        const QString path = s.mid(5);
        const QFileInfo fi(path);
        if (!fi.exists())
            return false;
        const QString suffix = fi.suffix().toLower();
        if (fi.isFile() && (suffix == "png" || suffix == "svg" || suffix == "ico" || suffix == "xpm" || suffix == "jpg"))
            icon = QIcon(path);
        else
            icon = QFileIconProvider().icon(fi); // exe resources (Windows), bundle icon (macOS)
    }
    if (icon.isNull())
        return false;
    QImage img = icon.pixmap(QSize(256, 256)).toImage();
    if (img.isNull())
        return false;
    img = eb_trim_corner_icon(img);
    if (img.width() != 64 || img.height() != 64)
        img = img.scaled(64, 64, Qt::KeepAspectRatio, Qt::SmoothTransformation);
    return img.save(QString::fromUtf8(out_path), "PNG");
}

// Height the window manager adds around EasyBoard's window (title bar + bottom border), so the
// minimum size can count the whole window. 0 while unknown (e.g. before the window is shown).
extern "C" int easyboard_frame_height() {
    for (QWindow *w : QGuiApplication::topLevelWindows()) {
        if (qobject_cast<QQuickWindow *>(w) && w->isVisible()) {
            const QMargins m = w->frameMargins();
            return m.top() + m.bottom();
        }
    }
    return 0;
}

// Themes: gives Qt's application palette the theme's colors ("role=#color;role=#color", see
// Main.qml loadTheme), so menus and pop-ups start out in the theme's colors instead of showing the
// system's for a moment. "" puts the system palette back. File dialogs get the system palette while
// they are open (easyboard_dialog_palette), so the system's own dialogs never wear the theme.
#include <QHash>
static QString g_themeSpec;            // the active theme's palette ("" = none)
static QPalette g_preThemePalette;     // the system palette from before the theme
static bool g_dialogOpen = false;

static void eb_system_palette() {
#ifdef Q_OS_WIN
    eb_apply_theme();
#else
    QGuiApplication::setPalette(QPalette()); // unset: back to the platform's palette, which keeps following it
#endif
}

static void eb_apply_spec() {
    static const QHash<QString, QPalette::ColorRole> roles = {
        {QStringLiteral("window"), QPalette::Window},       {QStringLiteral("windowText"), QPalette::WindowText},
        {QStringLiteral("base"), QPalette::Base},           {QStringLiteral("text"), QPalette::Text},
        {QStringLiteral("button"), QPalette::Button},       {QStringLiteral("buttonText"), QPalette::ButtonText},
        {QStringLiteral("highlight"), QPalette::Highlight}, {QStringLiteral("highlightedText"), QPalette::HighlightedText},
        {QStringLiteral("toolTipBase"), QPalette::ToolTipBase}, {QStringLiteral("toolTipText"), QPalette::ToolTipText},
        {QStringLiteral("link"), QPalette::Link},           {QStringLiteral("linkVisited"), QPalette::LinkVisited},
    };
    QPalette p = g_preThemePalette;
    for (const QString &kv : g_themeSpec.split(QLatin1Char(';'), Qt::SkipEmptyParts)) {
        const int eq = kv.indexOf(QLatin1Char('='));
        if (eq <= 0) continue;
        const auto it = roles.constFind(kv.left(eq));
        const QColor c(kv.mid(eq + 1));
        if (it != roles.constEnd() && c.isValid()) p.setColor(QPalette::All, *it, c);
    }
    QGuiApplication::setPalette(p);
}

extern "C" void easyboard_theme_palette(const char *spec) {
    const QString s = QString::fromUtf8(spec);
    if (g_themeSpec.isEmpty() && !s.isEmpty())
        g_preThemePalette = QGuiApplication::palette();
    g_themeSpec = s;
    if (g_dialogOpen) return;
    if (s.isEmpty()) eb_system_palette();
    else eb_apply_spec();
}

extern "C" void easyboard_dialog_palette(bool open) {
    g_dialogOpen = open;
    if (g_themeSpec.isEmpty()) return;
    if (open) eb_system_palette();
    else eb_apply_spec();
}

// The system accent color as "#rrggbb", also while a theme replaces the app's palette.
extern "C" int easyboard_system_accent(char *buf, int cap) {
#ifdef Q_OS_WIN
    const QColor c = eb_accent();
#else
    const QColor c = (g_themeSpec.isEmpty() ? QGuiApplication::palette() : g_preThemePalette).color(QPalette::Highlight);
#endif
    const QByteArray b = c.name(QColor::HexRgb).toUtf8();
    const int n = qMin(cap - 1, int(b.size()));
    if (n < 0) return 0;
    memcpy(buf, b.constData(), n);
    buf[n] = 0;
    return n;
}

// ---- pictures Qt can't open by itself (WebP, AVIF, HEIC/HEIF without Qt's image-format plugins)

// True when Qt can open the picture as it is.
extern "C" bool easyboard_image_readable(const char *path) {
    QImageReader r(QString::fromUtf8(path));
    r.setDecideFormatFromContent(true);
    return r.canRead();
}

#ifdef Q_OS_WIN
// Windows Imaging Component: WebP is built in, HEIC/HEIF and AVIF work when Windows has the HEIF
// Image Extensions / AV1 Video Extension (Windows 11 usually does).
static bool eb_native_to_png(const QString &src, const QString &dst) {
    const HRESULT init = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    bool ok = false;
    IWICImagingFactory *factory = nullptr;
    if (SUCCEEDED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory)))) {
        const QString native = QDir::toNativeSeparators(src);
        IWICBitmapDecoder *decoder = nullptr;
        if (SUCCEEDED(factory->CreateDecoderFromFilename(reinterpret_cast<LPCWSTR>(native.utf16()), nullptr, GENERIC_READ,
                                                         WICDecodeMetadataCacheOnDemand, &decoder))) {
            IWICBitmapFrameDecode *frame = nullptr;
            if (SUCCEEDED(decoder->GetFrame(0, &frame))) {
                IWICFormatConverter *conv = nullptr;
                if (SUCCEEDED(factory->CreateFormatConverter(&conv))
                    && SUCCEEDED(conv->Initialize(frame, GUID_WICPixelFormat32bppBGRA, WICBitmapDitherTypeNone, nullptr, 0.0,
                                                  WICBitmapPaletteTypeCustom))) {
                    UINT w = 0, h = 0;
                    if (SUCCEEDED(conv->GetSize(&w, &h)) && w > 0 && h > 0) {
                        // 32bppBGRA in memory is exactly QImage's ARGB32 (not premultiplied)
                        QImage img(int(w), int(h), QImage::Format_ARGB32);
                        if (!img.isNull()
                            && SUCCEEDED(conv->CopyPixels(nullptr, UINT(img.bytesPerLine()), UINT(img.sizeInBytes()), img.bits())))
                            ok = img.save(dst, "PNG");
                    }
                }
                if (conv)
                    conv->Release();
                frame->Release();
            }
            decoder->Release();
        }
        factory->Release();
    }
    if (SUCCEEDED(init))
        CoUninitialize();
    return ok;
}
#elif defined(Q_OS_MACOS)
// ImageIO reads WebP, HEIC/HEIF and AVIF (macOS 13+). The picture is turned the way the camera was held.
static bool eb_native_to_png(const QString &src, const QString &dst) {
    const QByteArray s = QFile::encodeName(src), d = QFile::encodeName(dst);
    CFURLRef in = CFURLCreateFromFileSystemRepresentation(nullptr, reinterpret_cast<const UInt8 *>(s.constData()), s.size(), false);
    CFURLRef out = CFURLCreateFromFileSystemRepresentation(nullptr, reinterpret_cast<const UInt8 *>(d.constData()), d.size(), false);
    bool ok = false;
    if (in && out) {
        if (CGImageSourceRef source = CGImageSourceCreateWithURL(in, nullptr)) {
            int maxSize = 8192;
            CFNumberRef max = CFNumberCreate(nullptr, kCFNumberIntType, &maxSize);
            const void *keys[] = { kCGImageSourceCreateThumbnailFromImageAlways, kCGImageSourceCreateThumbnailWithTransform,
                                   kCGImageSourceThumbnailMaxPixelSize };
            const void *values[] = { kCFBooleanTrue, kCFBooleanTrue, max };
            CFDictionaryRef opts = CFDictionaryCreate(nullptr, keys, values, 3, &kCFTypeDictionaryKeyCallBacks,
                                                      &kCFTypeDictionaryValueCallBacks);
            if (CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, opts)) {
                if (CGImageDestinationRef dest = CGImageDestinationCreateWithURL(out, CFSTR("public.png"), 1, nullptr)) {
                    CGImageDestinationAddImage(dest, image, nullptr);
                    ok = CGImageDestinationFinalize(dest);
                    CFRelease(dest);
                }
                CGImageRelease(image);
            }
            CFRelease(opts);
            CFRelease(max);
            CFRelease(source);
        }
    }
    if (in)
        CFRelease(in);
    if (out)
        CFRelease(out);
    return ok;
}
#else
static bool eb_native_to_png(const QString &, const QString &) { return false; }
#endif

// Converts a picture to PNG with the system's own decoder. False when the system can't read it
// (EasyBoard then tries FFmpeg).
extern "C" bool easyboard_image_to_png(const char *src, const char *dst) {
    return eb_native_to_png(QString::fromUtf8(src), QString::fromUtf8(dst));
}

// "Launch on startup" on Windows: the Run key in the registry, written directly (starting reg.exe
// for it could take several seconds).
extern "C" bool easyboard_run_at_login(bool enabled, const char *exe) {
#ifdef Q_OS_WIN
    QSettings run(QStringLiteral("HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Run"), QSettings::NativeFormat);
    if (enabled)
        run.setValue(QStringLiteral("EasyBoard"), QLatin1Char('"') + QDir::toNativeSeparators(QString::fromUtf8(exe)) + QLatin1Char('"'));
    else
        run.remove(QStringLiteral("EasyBoard"));
    run.sync();
    return run.status() == QSettings::NoError;
#else
    Q_UNUSED(enabled);
    Q_UNUSED(exe);
    return false;
#endif
}


