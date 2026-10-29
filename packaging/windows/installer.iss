#define RepoRoot AddBackslash(SourcePath) + "..\.."
#ifndef AppVersion
  #define AppVersion "1.1.0"
#endif
[Setup]
AppId={{8D254C86-F284-49D2-95EE-531652F63B01}
AppName=Window Control
AppVersion={#AppVersion}
AppPublisher=haoyuanwu
AppPublisherURL=https://github.com/haoyuanwu/window_control
AppSupportURL=https://github.com/haoyuanwu/window_control/issues
AppUpdatesURL=https://github.com/haoyuanwu/window_control/releases
DefaultDirName={localappdata}\Programs\WindowControl
DefaultGroupName=Window Control
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#RepoRoot}\build\releases
OutputBaseFilename=WindowControl-Setup-{#AppVersion}-Windows-x64
SetupIconFile={#RepoRoot}\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\window_control.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
VersionInfoVersion={#AppVersion}.0
VersionInfoDescription=Window Control Installer

[Languages]
Name: "chinesesimp"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; Flags: unchecked

[Files]
Source: "{#RepoRoot}\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#RepoRoot}\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#RepoRoot}\docs\THIRD_PARTY_NOTICES.md"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\Window Control"; Filename: "{app}\window_control.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\Window Control"; Filename: "{app}\window_control.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\window_control.exe"; Description: "启动 Window Control"; Flags: nowait postinstall skipifsilent

[Code]
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Command: String;
begin
  if CurUninstallStep = usUninstall then
    if RegQueryStringValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'WindowControl', Command) then
      if CompareText(Command, '"' + ExpandConstant('{app}\window_control.exe') + '"') = 0 then
        RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'WindowControl');
end;
