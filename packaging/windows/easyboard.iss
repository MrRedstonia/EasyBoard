; Inno Setup script for EasyBoard (https://jrsoftware.org/isinfo.php).
; Normally run through build-installer.ps1, which stages the files in ..\..\dist\EasyBoard first.

#ifndef AppVersion
  #define AppVersion "0.3.0"
#endif

[Setup]
AppId={{7C1B2E6A-5A0F-4C52-9B7B-EA5CB0A4D001}
AppName=EasyBoard
AppVersion={#AppVersion}
AppPublisher=MrRedstonia
AppPublisherURL=https://github.com/MrRedstonia/EasyBoard
AppSupportURL=https://github.com/MrRedstonia/EasyBoard/issues
; Per-user install: no admin prompt, updates are easy.
PrivilegesRequired=lowest
DefaultDirName={localappdata}\Programs\EasyBoard
DefaultGroupName=EasyBoard
DisableProgramGroupPage=yes
OutputDir=..\..\dist
OutputBaseFilename=EasyBoard-{#AppVersion}-setup
SetupIconFile=..\..\assets\app_icon.ico
UninstallDisplayIcon={app}\easyboard.exe
LicenseFile=..\..\LICENSE
Compression=lzma2
SolidCompression=yes
; follows Windows' light or dark mode (needs Inno Setup 6.6 or newer)
WizardStyle=modern dynamic
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=yes

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Files]
Source: "..\..\dist\EasyBoard\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\EasyBoard"; Filename: "{app}\easyboard.exe"
Name: "{autodesktop}\EasyBoard"; Filename: "{app}\easyboard.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\easyboard.exe"; Description: "Start EasyBoard"; Flags: nowait postinstall skipifsilent

; The user's sounds/settings live in %LOCALAPPDATA%\EasyBoard and are intentionally kept on uninstall.
