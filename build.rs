use cxx_qt_build::{CxxQtBuilder, QmlModule};

fn main() {
    // Windows: embed the app icon (assets/app_icon.ico) and version info into easyboard.exe.
    #[cfg(windows)]
    {
        let mut res = winresource::WindowsResource::new();
        res.set_icon("assets/app_icon.ico");
        res.set("ProductName", "EasyBoard");
        res.set("FileDescription", "EasyBoard");
        res.set("CompanyName", "MrRedstonia");
        if let Err(e) = res.compile() {
            println!("cargo:warning=could not embed the Windows icon: {e}");
        }
    }
    println!("cargo:rerun-if-changed=assets/app_icon.ico");

    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();

    // App routing on macOS (Core Audio process taps): Objective-C++ with ARC, built on its own
    // so the flags don't reach the C++ shim.
    if target_os == "macos" {
        cc::Build::new()
            .cpp(true)
            .file("cpp/apptap_mac.mm")
            .flag("-fobjc-arc")
            .flag("-std=c++17")
            .compile("easyboard_apptap");
        for fw in ["CoreAudio", "AppKit", "Foundation", "ImageIO", "CoreGraphics", "CoreFoundation"] {
            println!("cargo:rustc-link-lib=framework={fw}");
        }
    }
    // pictures through the Windows Imaging Component (cpp/shim.cpp)
    if target_os == "windows" {
        for lib in ["windowscodecs", "ole32"] {
            println!("cargo:rustc-link-lib={lib}");
        }
    }
    println!("cargo:rerun-if-changed=cpp/apptap_mac.mm");
    println!("cargo:rerun-if-changed=cpp/apptap_win.cpp");

    CxxQtBuilder::new()
        .qt_module("Quick")
        .qt_module("QuickControls2")
        .qt_module("Widgets")
        .qml_module(QmlModule {
            uri: "EasyBoard",
            version_major: 1,
            version_minor: 0,
            rust_files: &["src/ui/backend.rs"],
            qml_files: &[
                "qml/Main.qml",
                "qml/SetupWizard.qml",
                "qml/BoardPage.qml",
                "qml/SoundTile.qml",
                "qml/EditorPanel.qml",
                "qml/SettingsPage.qml",
                "qml/EbButton.qml",
                "qml/EbField.qml",
                "qml/EbCombo.qml",
                "qml/EbSlider.qml",
                "qml/EbSwitch.qml",
                "qml/RoundedImage.qml",
                "qml/StudioPage.qml",
                "qml/EbScrollBar.qml",
                "qml/EbWheel.qml",
                "qml/EbHotkey.qml",
                "qml/TrayMenu.qml",
                "qml/EbAudioPicker.qml",
                "qml/LibraryPage.qml",
                "qml/AppRoutingPage.qml",
                "qml/Wallpaper.qml",
                "qml/ThemesPage.qml",
                "qml/EbFileDialog.qml",
                "qml/GlassBackdrop.qml",
                "qml/GlassSurface.qml",
                "qml/Shadow.qml",
                "qml/Sheen.qml",
                "qml/Rim.qml",
                "qml/LiquidPopup.qml",
                "qml/GlassTip.qml",
            ],
            ..Default::default()
        })
        .cc_builder(|cc| {
            cc.file("cpp/shim.cpp");
            // App routing on Windows (WASAPI process loopback)
            if target_os == "windows" {
                cc.file("cpp/apptap_win.cpp");
            }
        })
        .build();

    println!("cargo:rerun-if-changed=cpp/shim.cpp");
    println!("cargo:rerun-if-changed=assets/app_icon.png");
    println!("cargo:rerun-if-changed=assets/tray_icon.png");
    println!("cargo:rerun-if-changed=assets/tray_icon_light.png");
}
