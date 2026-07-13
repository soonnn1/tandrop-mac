; TanDrop Windows installer.
; In GitHub Actions pass:
;   /DSourceDir="app\build\windows\x64\runner\Release"
;   /DIconFile="app\assets\packaging\logo.ico"
;   /DOutputDir="app\dist"

#define MyAppName "TanDrop"
#define MyAppVersion "1.17.0"
#define MyAppPublisher "TanDrop"
#define MyAppURL ""
#define MyAppExeName "TanDrop.exe"
#ifndef SourceDir
#define SourceDir "..\app\build\windows\x64\runner\Release"
#endif
#ifndef IconFile
#define IconFile "..\app\assets\packaging\logo.ico"
#endif
#ifndef OutputDir
#define OutputDir "..\app\dist"
#endif

[Setup]
; NOTE: The value of AppId uniquely identifies this application. Do not use the same AppId value in installers for other applications.
; (To generate a new GUID, click Tools | Generate GUID inside the IDE.)
AppId={{30A0EA32-4328-4F6F-BBE0-2B29D9A9E231}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
;AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DisableProgramGroupPage=yes
; Uncomment the following line to run in non administrative install mode (install for current user only.)
;PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir={#OutputDir}
OutputBaseFilename=TanDrop-Setup
SetupIconFile={#IconFile}
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible
ArchitecturesAllowed=x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesesimplified"; MessagesFile: ".\Languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\*.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs
; NOTE: Don't use "Flags: ignoreversion" on any shared system files

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}";
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
