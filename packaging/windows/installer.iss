; QRStream Windows installer — Inno Setup 6.
;
; Build (see .github/workflows/release.yml "Build Windows installer"):
;   iscc /DMyAppVersion=<version> /DReleaseDir=<abs path to flutter Release> installer.iss
;
; The installer bundles the whole Flutter release directory — the exe, the
; Flutter engine DLLs, the Rust codec DLL and the app-local MSVC runtime
; (msvcp140.dll / vcruntime140.dll / vcruntime140_1.dll, copied into the
; release dir by the workflow) — so the app runs on machines without the
; VC++ redistributable installed.
;
; Inno Setup resolves relative Source: paths against THIS script's directory,
; so ReleaseDir is passed as an absolute path by the workflow.

#ifndef MyAppVersion
  #define MyAppVersion "1.0.0"
#endif

#ifndef ReleaseDir
  #define ReleaseDir "build\windows\x64\runner\Release"
#endif

#define MyAppName "QRStream"
#define MyAppPublisher "QRStream"
#define MyAppExeName "qr_data_transfer.exe"

[Setup]
AppId={{8F2E1A6C-9B4D-4E0F-8C5A-2D7B3E1F6A09}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\QRStream
DefaultGroupName=QRStream
DisableProgramGroupPage=yes
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=output
OutputBaseFilename=qrstream-{#MyAppVersion}-windows-setup
SetupIconFile=..\..\flutter_app\windows_templates\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible
ArchitecturesAllowed=x64compatible
; Signing is wired but intentionally OFF — QRStream ships unsigned and is
; submitted to the Microsoft Security Intelligence portal instead. To enable,
; set a SignTool below (see the Inno Setup docs) and pass /Ssigntool to ISCC.
; SignTool=signtool /f $qf /t http://timestamp.digicert.com /fd sha256 $f

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#ReleaseDir}\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#ReleaseDir}\*.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#ReleaseDir}\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\QRStream"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\QRStream"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,QRStream}"; Flags: nowait postinstall skipifsilent
