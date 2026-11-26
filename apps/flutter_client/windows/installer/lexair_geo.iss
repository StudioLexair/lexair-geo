; VIGÍA (Lexair Geo) · Instalador offline para Windows 10/11 x64 (Inno Setup 6.7)
; Compilación (CI): iscc /DAppVersion=0.3.0 /DSourceDir=...\Release /DOutDir=...\out
;   [/DServidorDir=...\servidor]  → añade la tarea «Servidor integrado» con la
;   base de datos + API empaquetados (todo en uno).
; Instalación silenciosa: Vigia-Setup.exe /VERYSILENT /SERVERURL=https://geo.internal /CAFILE=C:\ruta\ca.crt
; No descarga nada: todo (exe, DLL, data, servidor integrado) va dentro del instalador.

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
AppName=VIGÍA (Lexair Geo)
AppVersion={#AppVersion}
AppPublisher=Studio Lexair
DefaultDirName={autopf}\LexairGeo
DefaultGroupName=VIGÍA
DisableProgramGroupPage=yes
OutputDir={#OutDir}
OutputBaseFilename=Vigia-{#AppVersion}-Setup-x64
Compression=lzma2/max
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
PrivilegesRequired=admin
WizardStyle=modern
SetupIconFile=..\runner\resources\app_icon.ico
WizardSmallImageFile=wizard_logo.png
LicenseFile=LICENCIA.txt
InfoBeforeFile=BIENVENIDA.txt
UninstallDisplayName=VIGÍA (Lexair Geo)
UninstallDisplayIcon={app}\lexair_geo.exe
VersionInfoCompany=Studio Lexair
VersionInfoProductName=VIGÍA
VersionInfoProductVersion={#AppVersion}
VersionInfoTextVersion={#AppVersion}
SetupLogging=yes

[Languages]
Name: "es"; MessagesFile: "compiler:Languages\Spanish.isl"

[Tasks]
Name: "desktopicon"; Description: "Crear acceso directo en el escritorio"; Flags: unchecked
Name: "trustca"; Description: "Confiar en la CA interna de VIGÍA (si se indica un certificado)"; Check: HasCaFile
#ifdef ServidorDir
Name: "integrado"; Description: "Instalar servidor integrado (base de datos local + API). Desmárquelo si este equipo solo será cliente del servidor de la red."; Flags: checkedonce
#endif

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SourceDir}\datos_ejemplo\*"; DestDir: "{app}\datos_ejemplo"; Flags: ignoreversion
#ifdef ServidorDir
Source: "{#ServidorDir}\*"; DestDir: "{app}\servidor"; Flags: ignoreversion recursesubdirs createallsubdirs; Tasks: integrado
#endif

[InstallDelete]
; Iconos de versiones anteriores (LEXAIR GEO) para que no queden duplicados.
Type: files; Name: "{autodesktop}\LEXAIR GEO.lnk"
Type: files; Name: "{group}\LEXAIR GEO.lnk"
Type: files; Name: "{group}\Desinstalar LEXAIR GEO.lnk"
Type: files; Name: "{commondesktop}\LEXAIR GEO.lnk"
Type: files; Name: "{commonprograms}\LEXAIR GEO\*.*"
Type: dirifempty; Name: "{commonprograms}\LEXAIR GEO"

[Dirs]
Name: "{commonappdata}\LexairGeo"; Permissions: users-modify

[Icons]
Name: "{group}\VIGÍA"; Filename: "{app}\lexair_geo.exe"
Name: "{group}\Desinstalar VIGÍA"; Filename: "{uninstallexe}"
Name: "{autodesktop}\VIGÍA"; Filename: "{app}\lexair_geo.exe"; Tasks: desktopicon

[Run]
Filename: "{sys}\certutil.exe"; Parameters: "-f -addstore Root ""{commonappdata}\LexairGeo\lexair-geo-ca.crt"""; \
  Flags: runhidden waituntilterminated; Tasks: trustca; StatusMsg: "Instalando la CA interna…"
Filename: "{app}\lexair_geo.exe"; Description: "Abrir VIGÍA"; Flags: nowait postinstall skipifsilent

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
  ServerPage := CreateInputQueryPage(wpSelectDir, 'Servidor', 'Dirección del servidor VIGÍA',
    'El servidor integrado usa la dirección local http://127.0.0.1:3000. Para trabajar en la red indique la URL interna (por ejemplo https://geo.internal); puede cambiarse después desde la pantalla de acceso.');
  ServerPage.Add('URL del servidor:', False);
  if ParamValue('SERVERURL') <> '' then
    ServerPage.Values[0] := ParamValue('SERVERURL')
  else begin
#ifdef ServidorDir
    ServerPage.Values[0] := 'http://127.0.0.1:3000';
#else
    ServerPage.Values[0] := 'https://geo.internal';
#endif
  end;
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
var Cfg, Url, CaDest, Term, Datos, Mensaje: string;
begin
  // Versiones anteriores: preguntar si se conservan los datos existentes.
  if CurStep = ssInstall then begin
    Datos := ExpandConstant('{localappdata}\VIGIA\datos');
    if DirExists(Datos) then begin
      Mensaje := 'Se ha detectado una instalación anterior con datos guardados.' #13#10#13#10 +
        '¿Desea CONSERVAR los datos existentes? (Recomendado: conserva la base, ' +
        'las zonas y las ubicaciones marcadas.)' #13#10#13#10 +
        'Elija «No» solo si quiere empezar de cero; en ese caso los datos ' +
        'anteriores se eliminarán.';
      if MsgBox(Mensaje, mbConfirmation, MB_YESNO) = IDNO then
        DelTree(Datos, True, True, True);
    end;
  end;
  if CurStep = ssPostInstall then begin
    CaDest := ExpandConstant('{commonappdata}\LexairGeo\lexair-geo-ca.crt');
    if HasCaFile then
      FileCopy(ParamValue('CAFILE'), CaDest, False);
    // Plantilla de terminología (solo si no existe ninguna).
    Term := ExpandConstant('{commonappdata}\LexairGeo\terminologia.ejemplo.json');
    if not FileExists(Term) then
      SaveStringToFile(Term,
        '{' #13#10 '  "sujetoSingular": "Ficha",' #13#10 '  "sujetoPlural": "Fichas",' #13#10 +
        '  "paseSingular": "Permiso",' #13#10 '  "pasePlural": "Permisos",' #13#10 +
        '  "kardexTitulo": "Registros",' #13#10 '  "kardexTituloCorto": "REGISTROS",' #13#10 +
        '  "importTitulo": "Importar fichas (Excel XML)",' #13#10 '  "unidadLabel": "Unidad",' #13#10 +
        '  "orgNombre": "VIGÍA",' #13#10 +
        '  "_ayuda": "Copie este fichero como terminologia.json y edite los valores; reinicie VIGÍA para aplicar."' #13#10 '}' #13#10, False);
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
