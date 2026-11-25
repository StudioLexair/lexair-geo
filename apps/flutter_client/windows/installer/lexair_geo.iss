; LEXAIR GEO · Instalador offline para Windows 10/11 x64 (Inno Setup 6.7)
; Compilación (CI): iscc /DAppVersion=0.1.0 /DSourceDir=...\Release /DOutDir=...\out lexair_geo.iss
; Instalación silenciosa: LexairGeo-Setup.exe /VERYSILENT /SERVERURL=https://geo.internal /CAFILE=C:\ruta\ca.crt
; No descarga nada: todo (exe, DLL, data) va dentro del instalador.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #error Defina /DSourceDir con la carpeta Release de flutter build windows
#endif
#ifndef OutDir
  #define OutDir "."
#endif

[Setup]
AppId={{6C1E2B8E-3F0D-4C47-9C6B-1E5A0B7D4E21}
AppName=LEXAIR GEO
AppVersion={#AppVersion}
AppPublisher=Studio Lexair
DefaultDirName={autopf}\LexairGeo
DefaultGroupName=LEXAIR GEO
DisableProgramGroupPage=yes
OutputDir={#OutDir}
OutputBaseFilename=LexairGeo-{#AppVersion}-Setup-x64
Compression=lzma2/max
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
PrivilegesRequired=admin
WizardStyle=modern
UninstallDisplayIcon={app}\lexair_geo.exe
SetupLogging=yes

[Languages]
Name: "es"; MessagesFile: "compiler:Languages\Spanish.isl"

[Tasks]
Name: "desktopicon"; Description: "Crear acceso directo en el escritorio"; Flags: unchecked
Name: "trustca"; Description: "Confiar en la CA interna de LEXAIR GEO (si se indica un certificado)"; Check: HasCaFile

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Dirs]
Name: "{commonappdata}\LexairGeo"; Permissions: users-readexec

[Icons]
Name: "{group}\LEXAIR GEO"; Filename: "{app}\lexair_geo.exe"
Name: "{group}\Desinstalar LEXAIR GEO"; Filename: "{uninstallexe}"
Name: "{autodesktop}\LEXAIR GEO"; Filename: "{app}\lexair_geo.exe"; Tasks: desktopicon

[Run]
Filename: "{sys}\certutil.exe"; Parameters: "-f -addstore Root ""{commonappdata}\LexairGeo\lexair-geo-ca.crt"""; \
  Flags: runhidden waituntilterminated; Tasks: trustca; StatusMsg: "Instalando la CA interna…"
Filename: "{app}\lexair_geo.exe"; Description: "Abrir LEXAIR GEO"; Flags: nowait postinstall skipifsilent

[Code]
var
  ServerPage: TInputQueryWizardPage;

function ParamValue(const Name: string): string;
var I: Integer; P: string;
begin
  Result := '';
  for I := 1 to ParamCount do begin
    P := ParamStr(I);
    if CompareText(Copy(P, 1, Length(Name) + 2), '/' + Name + '=') = 0 then
      Result := Copy(P, Length(Name) + 3, MaxInt);
  end;
end;

function HasCaFile: Boolean;
begin
  Result := (ParamValue('CAFILE') <> '') and FileExists(ParamValue('CAFILE'));
end;

procedure InitializeWizard;
begin
  ServerPage := CreateInputQueryPage(wpSelectDir, 'Servidor', 'Dirección del servidor LEXAIR GEO',
    'Indique la URL interna (por ejemplo https://geo.internal). Puede cambiarse después desde la pantalla de acceso.');
  ServerPage.Add('URL del servidor:', False);
  if ParamValue('SERVERURL') <> '' then
    ServerPage.Values[0] := ParamValue('SERVERURL')
  else
    ServerPage.Values[0] := 'https://geo.internal';
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var U: string;
begin
  Result := True;
  if CurPageID = ServerPage.ID then begin
    U := Trim(ServerPage.Values[0]);
    if (Pos('https://', LowerCase(U)) <> 1) and (Pos('http://', LowerCase(U)) <> 1) then begin
      MsgBox('La URL debe empezar por https:// (o http:// en pruebas).', mbError, MB_OK);
      Result := False;
    end;
  end;
end;

function JsonEscape(const S: string): string;
begin
  Result := S;
  StringChangeEx(Result, '\', '\\', True);
  StringChangeEx(Result, '"', '\"', True);
end;

procedure CurStepChanged(CurStep: TSetupStep);
var Cfg, Url, CaDest: string;
begin
  if CurStep = ssPostInstall then begin
    CaDest := ExpandConstant('{commonappdata}\LexairGeo\lexair-geo-ca.crt');
    if HasCaFile then
      FileCopy(ParamValue('CAFILE'), CaDest, False);
    Cfg := ExpandConstant('{commonappdata}\LexairGeo\config.json');
    // No sobrescribe una configuración existente (actualizaciones).
    if not FileExists(Cfg) then begin
      Url := Trim(ServerPage.Values[0]);
      while (Length(Url) > 0) and (Url[Length(Url)] = '/') do
        Url := Copy(Url, 1, Length(Url) - 1);
      if FileExists(CaDest) then
        SaveStringToFile(Cfg, '{' #13#10 '  "serverUrl": "' + JsonEscape(Url) + '",' #13#10 +
          '  "healthPollSeconds": 15,' #13#10 '  "caCertificatePath": "' + JsonEscape(CaDest) + '"' #13#10 '}' #13#10, False)
      else
        SaveStringToFile(Cfg, '{' #13#10 '  "serverUrl": "' + JsonEscape(Url) + '",' #13#10 +
          '  "healthPollSeconds": 15' #13#10 '}' #13#10, False);
    end;
  end;
end;
