; VIGÍA (Lexair Geo) · Instaladores offline para Windows 10/11 x64 (Inno Setup 6.7)
; UN SOLO SCRIPT produce las TRES variantes según /DModo:
;   /DModo=cliente   → Vigia-X.Y.Z-Cliente-x64.exe   (solo el programa, ~15 MB)
;   /DModo=servidor  → Vigia-X.Y.Z-Servidor-x64.exe  (programa + servidor integrado)
;   /DModo=todo      → Vigia-X.Y.Z-TodoEnUno-x64.exe (elige rol al instalar:
;                      Servidor de red / Prueba local / Solo cliente; cambiable
;                      después desde el asistente inicial del programa)
; Compilación (CI):
;   iscc /DAppVersion=0.7.0 /DSourceDir=...\Release [/DServidorDir=...\servidor]
;        /DManifiestoFile=...\manifiesto.txt /DOutDir=...\out /DModo=todo lexair_geo.iss
; Instalación silenciosa:
;   Vigia-Setup.exe /VERYSILENT /ROLE=red|local|cliente /SERVERURL=https://geo.internal /CAFILE=C:\ruta\ca.crt
; No descarga nada: todo (exe, DLL, data, servidor integrado, música, fondo) va dentro.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #error Defina /DSourceDir con la carpeta Release de flutter build windows
#endif
#ifndef ManifiestoFile
  #error Defina /DManifiestoFile con el manifiesto SHA-256 generado por CI
#endif
#ifndef Modo
  #ifdef ServidorDir
    #define Modo "todo"
  #else
    #define Modo "cliente"
  #endif
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
#if Modo == "cliente"
OutputBaseFilename=Vigia-{#AppVersion}-Cliente-x64
#elseif Modo == "servidor"
OutputBaseFilename=Vigia-{#AppVersion}-Servidor-x64
#else
OutputBaseFilename=Vigia-{#AppVersion}-TodoEnUno-x64
#endif
; Cliente (pequeño): máxima compresión. Paquetes grandes (pg/node): nivel
; normal para extraer bastante más rápido a cambio de poco tamaño extra.
#if Modo == "cliente"
Compression=lzma2/max
#else
Compression=lzma2/normal
#endif
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
PrivilegesRequired=admin
WizardStyle=modern
WizardResizable=no
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

[Files]
; Programa. CI prepara SourceDir SIN la carpeta servidor (robocopy /XD), así
; el servidor solo entra por su propia entrada según el rol elegido.
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
#ifdef ServidorDir
; Servidor integrado (PostgreSQL+PostGIS, Node, API, SQL, mapas): solo roles «red» y «local»
Source: "{#ServidorDir}\*"; DestDir: "{app}\servidor"; Flags: ignoreversion recursesubdirs createallsubdirs; Check: InstalarServidor
#endif
; Manifiesto SHA-256 de ESTA versión (para comparar con la anterior)
Source: "{#ManifiestoFile}"; DestDir: "{tmp}"; Flags: deleteafterinstall dontcopy
; Música y fondo del asistente
Source: "musica.wav"; DestDir: "{tmp}"; Flags: deleteafterinstall dontcopy
Source: "fondo.bmp"; DestDir: "{tmp}"; Flags: deleteafterinstall dontcopy
; Guía rápida (SmartScreen, requisitos, modos, instalación silenciosa)
Source: "LEEME-VIGIA.txt"; DestDir: "{app}"; Flags: ignoreversion

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
Name: "{group}\Guía rápida (LEEME)"; Filename: "{app}\LEEME-VIGIA.txt"
Name: "{autodesktop}\VIGÍA"; Filename: "{app}\lexair_geo.exe"; Tasks: desktopicon

[Run]
Filename: "{sys}\certutil.exe"; Parameters: "-f -addstore Root ""{commonappdata}\LexairGeo\lexair-geo-ca.crt"""; \
  Flags: runhidden waituntilterminated; Tasks: trustca; StatusMsg: "Instalando la CA interna…"
Filename: "{app}\lexair_geo.exe"; Description: "Abrir VIGÍA"; Flags: nowait postinstall skipifsilent

[Code]
var
  ServerPage: TInputQueryWizardPage;
  RolePage: TInputOptionWizardPage;
  Rol: string;              // red · local · cliente
  MusicaSonando: Boolean;
  BotonMusica: TNewButton;
  FondoBienvenida, FondoFinal: TBitmapImage;
  NuevosN, CambiadosN, ObsoletosN: Integer;
  ObsoletosLista: TStringList;
  FijoFinal: Boolean;

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

// ---------------------------------------------------------------------------
// Música del asistente (MCI, en bucle) con botón de silencio
// ---------------------------------------------------------------------------
procedure MciSendStringW(Cmd: string; Buf: string; Size: Integer; Hwnd: Integer);
  external 'mciSendStringW@winmm.dll stdcall delayload';

procedure Mci(const Cmd: string);
var Resp: string;
begin
  SetLength(Resp, 256);
  MciSendStringW(Cmd, Resp, 256, 0);
end;

procedure MusicaIniciar;
begin
  if not FileExists(ExpandConstant('{tmp}\musica.wav')) then Exit;
  Mci('open "' + ExpandConstant('{tmp}\musica.wav') + '" type waveaudio alias vigmus');
  Mci('play vigmus repeat');
  MusicaSonando := True;
end;

procedure MusicaAlternar(Sender: TObject);
begin
  if MusicaSonando then begin
    Mci('pause vigmus');
    BotonMusica.Caption := 'Reproducir música';
    MusicaSonando := False;
  end else begin
    Mci('play vigmus repeat');
    BotonMusica.Caption := 'Silencio';
    MusicaSonando := True;
  end;
end;

procedure MusicaParar;
begin
  Mci('stop vigmus');
  Mci('close vigmus');
  MusicaSonando := False;
end;

// ---------------------------------------------------------------------------
// Fondo del asistente en las páginas de bienvenida y final
// ---------------------------------------------------------------------------
procedure FondoColocar;
begin
  FondoBienvenida.BoundsRect := WizardForm.WelcomePage.ClientRect;
  FondoFinal.BoundsRect := WizardForm.FinishedPage.ClientRect;
end;

procedure FondoCargar;
begin
  ExtractTemporaryFile('fondo.bmp');
  FondoBienvenida := TBitmapImage.Create(WizardForm);
  FondoBienvenida.Bitmap.LoadFromFile(ExpandConstant('{tmp}\fondo.bmp'));
  FondoBienvenida.Stretch := True;
  FondoBienvenida.Parent := WizardForm.WelcomePage;
  FondoBienvenida.SendToBack;
  FondoFinal := TBitmapImage.Create(WizardForm);
  FondoFinal.Bitmap.LoadFromFile(ExpandConstant('{tmp}\fondo.bmp'));
  FondoFinal.Stretch := True;
  FondoFinal.Parent := WizardForm.FinishedPage;
  FondoFinal.SendToBack;
  FondoColocar;
  // Texto blanco para que se lea sobre el mapa oscuro
  WizardForm.WelcomeLabel1.Font.Color := clWhite;
  WizardForm.WelcomeLabel2.Font.Color := clWhite;
  WizardForm.FinishedHeadingLabel.Font.Color := clWhite;
  WizardForm.FinishedLabel.Font.Color := clWhite;
end;

// ---------------------------------------------------------------------------
// Manifiesto SHA-256: comparación con la versión anterior
// Formato de cada línea: "<sha256>  <ruta relativa>"
// ---------------------------------------------------------------------------
procedure ManifiestoCargar(const Ruta: string; const Rutas, Hashes: TStringList);
var Lista: TStringList; I, P: Integer; L: string;
begin
  Lista := TStringList.Create;
  try
    Lista.LoadFromFile(Ruta);
    for I := 0 to Lista.Count - 1 do begin
      L := Trim(Lista[I]);
      P := Pos('  ', L);
      if (Length(L) > 66) and (P = 65) then begin
        Rutas.Add(Trim(Copy(L, 66, MaxInt)));
        Hashes.Add(Copy(L, 1, 64));
      end;
    end;
    // Rutas y Hashes quedan paralelos (mismo orden): no ordenar.
  finally
    Lista.Free;
  end;
end;

function BuscarEn(const Lista: TStringList; const Ruta: string): Integer;
var I: Integer;
begin
  Result := -1;
  for I := 0 to Lista.Count - 1 do
    if CompareText(Lista[I], Ruta) = 0 then begin
      Result := I;
      Break;
    end;
end;

function ManifiestoComparar(const RutaNueva, RutaVieja: string): Boolean;
var NuevosR, NuevosH, ViejosR, ViejosH: TStringList;
    I, Idx: Integer;
begin
  Result := False;
  NuevosN := 0; CambiadosN := 0; ObsoletosN := 0;
  if not FileExists(RutaNueva) then Exit;
  NuevosR := TStringList.Create; NuevosH := TStringList.Create;
  ViejosR := TStringList.Create; ViejosH := TStringList.Create;
  try
    ManifiestoCargar(RutaNueva, NuevosR, NuevosH);
    if FileExists(RutaVieja) then begin
      ManifiestoCargar(RutaVieja, ViejosR, ViejosH);
      // nuevos y modificados: lo que trae esta versión
      for I := 0 to NuevosR.Count - 1 do begin
        Idx := BuscarEn(ViejosR, NuevosR[I]);
        if Idx < 0 then
          NuevosN := NuevosN + 1
        else if ViejosH[Idx] <> NuevosH[I] then
          CambiadosN := CambiadosN + 1;
      end;
      // obsoletos: estaba en la versión anterior y ya no viene
      for I := 0 to ViejosR.Count - 1 do begin
        if BuscarEn(NuevosR, ViejosR[I]) < 0 then begin
          ObsoletosN := ObsoletosN + 1;
          ObsoletosLista.Add(ViejosR[I]);
        end;
      end;
    end else begin
      NuevosN := NuevosR.Count; // primera instalación con manifiesto
    end;
    Result := True;
  finally
    NuevosR.Free; NuevosH.Free; ViejosR.Free; ViejosH.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Roles: servidor de red · prueba local · solo cliente
// ---------------------------------------------------------------------------
function InstalarServidor: Boolean;
begin
  #ifdef ServidorDir
  if ParamValue('ROLE') <> '' then
    Result := (CompareText(Rol, 'red') = 0) or (CompareText(Rol, 'local') = 0)
  else if RolePage = nil then
    Result := True   // modo servidor fijo
  else
    Result := RolePage.Values[0] or RolePage.Values[1];
  #else
  Result := False;
  #endif
end;

procedure AbrirFirewall;
var Codigo: Integer;
begin
  // Solo «servidor de red»: abre el puerto de la API a los clientes de la red.
  Exec(ExpandConstant('{sys}\netsh.exe'),
    'advfirewall firewall add rule name="VIGIA Servidor" dir=in action=allow protocol=TCP localport=3000',
    '', SW_HIDE, ewWaitUntilTerminated, Codigo);
end;

procedure InitializeWizard;
var I: Integer;
begin
  Rol := ParamValue('ROLE');
  if (CompareText(Rol, 'red') <> 0) and (CompareText(Rol, 'local') <> 0) and
     (CompareText(Rol, 'cliente') <> 0) then
    Rol := '';

  #ifdef ServidorDir
  if (ParamValue('ROLE') = '') and (CompareText('{#Modo}', 'todo') = 0) then begin
    RolePage := CreateInputOptionPage(wpWelcome, 'Tipo de instalación',
      '¿Cómo se usará VIGÍA en este equipo?',
      'Puede cambiarse después desde el asistente inicial del programa.', True, False);
    RolePage.Add('Servidor de red (guarda la base de datos y atiende a los demás equipos)');
    RolePage.Add('Prueba local (servidor y programa en este equipo, sin red)');
    RolePage.Add('Solo cliente (se conecta al servidor de la red)');
    RolePage.Values[0] := True;
  end;
  #endif

  ServerPage := CreateInputQueryPage(wpSelectDir, 'Servidor', 'Dirección del servidor VIGÍA',
    'El servidor integrado usa la dirección local http://127.0.0.1:3000. Para trabajar en la red indique la URL interna (por ejemplo https://geo.internal); puede cambiarse después desde la pantalla de acceso.');
  ServerPage.Add('URL del servidor:', False);
  if ParamValue('SERVERURL') <> '' then
    ServerPage.Values[0] := ParamValue('SERVERURL')
  else if InstalarServidor then
    ServerPage.Values[0] := 'http://127.0.0.1:3000'
  else
    ServerPage.Values[0] := 'https://geo.internal';

  // Música de fondo con botón de silencio (esquina inferior izquierda,
  // fuera del camino de los botones y del logotipo pequeño)
  ExtractTemporaryFile('musica.wav');
  BotonMusica := TNewButton.Create(WizardForm);
  BotonMusica.Parent := WizardForm;
  BotonMusica.Caption := 'Silencio';
  BotonMusica.Left := ScaleX(12);
  BotonMusica.Top := WizardForm.NextButton.Top;
  BotonMusica.Width := ScaleX(96);
  BotonMusica.Height := WizardForm.NextButton.Height;
  BotonMusica.OnClick := @MusicaAlternar;
  MusicaIniciar;

  ObsoletosLista := TStringList.Create;
  NuevosN := 0; CambiadosN := 0; ObsoletosN := 0;
  FijoFinal := False;
  FondoCargar;
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;
  if (RolePage <> nil) and (PageID = RolePage.ID) and (ParamValue('ROLE') <> '') then
    Result := True;  // rol fijado por /ROLE=
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var U, Msg, Vieja: string;
begin
  Result := True;
  if (RolePage <> nil) and (CurPageID = RolePage.ID) then begin
    if RolePage.Values[0] then Rol := 'red'
    else if RolePage.Values[1] then Rol := 'local'
    else Rol := 'cliente';
    // Ajustar la URL por defecto al modo elegido (si el usuario no fijó una)
    if ParamValue('SERVERURL') = '' then begin
      if Rol = 'cliente' then
        ServerPage.Values[0] := 'https://geo.internal'
      else
        ServerPage.Values[0] := 'http://127.0.0.1:3000';
    end;
  end;
  if CurPageID = ServerPage.ID then begin
    U := Trim(ServerPage.Values[0]);
    if (Pos('https://', LowerCase(U)) <> 1) and (Pos('http://', LowerCase(U)) <> 1) then begin
      MsgBox('La URL debe empezar por https:// (o http:// en pruebas).', mbError, MB_OK);
      Result := False;
    end;
  end;
  // Comparación con la versión anterior (antes de tocar nada)
  if CurPageID = wpReady then begin
    ExtractTemporaryFile('manifiesto.txt');
    Vieja := ExpandConstant('{app}\manifiesto.txt');
    if ManifiestoComparar(ExpandConstant('{tmp}\manifiesto.txt'), Vieja) and
       (FileExists(Vieja)) and (NuevosN + CambiadosN + ObsoletosN > 0) then begin
      Msg := 'Cambios frente a la versión anterior:' #13#10;
      Msg := Msg + '· ' + IntToStr(NuevosN) + ' fichero(s) nuevos' #13#10;
      Msg := Msg + '· ' + IntToStr(CambiadosN) + ' actualizado(s)' #13#10;
      Msg := Msg + '· ' + IntToStr(ObsoletosN) + ' de la versión anterior ya no se usan (se retirarán)';
      MsgBox(Msg, mbInformation, MB_OK);
    end;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var Cfg, Url, CaDest, Term, Datos, Mensaje, I: string;
    N: Integer;
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
    // Retirar los ficheros de la versión anterior que esta versión no usa.
    for N := 0 to ObsoletosLista.Count - 1 do begin
      I := ExpandConstant('{app}\') + ObsoletosLista[N];
      if FileExists(I) then DeleteFile(I);
    end;
  end;
  if CurStep = ssPostInstall then begin
    if InstalarServidor and ((Rol = 'red') or (Rol = '')) then AbrirFirewall;
    // Manifiesto para la próxima actualización
    if FileExists(ExpandConstant('{tmp}\manifiesto.txt')) then
      FileCopy(ExpandConstant('{tmp}\manifiesto.txt'), ExpandConstant('{app}\manifiesto.txt'), False);
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

procedure CurPageChanged(CurPageID: Integer);
var RTF, Linea, Url: string;
begin
  if CurPageID = wpFinished then begin
    Url := Trim(ServerPage.Values[0]);
    RTF := '{\rtf1\ansi\deff0{\fonttbl{\f0\fnil Segoe UI;}}\fs16\b Resumen de la instalación\b0\line ';
    RTF := RTF + RtfLinea('Programa VIGÍA ' + '{#AppVersion}' + ' instalado en: ' + ExpandConstant('{app}'));
    if InstalarServidor then begin
      RTF := RTF + RtfLinea('Servidor integrado instalado (base de datos y API en este equipo)');
      if Rol = 'red' then
        RTF := RTF + RtfLinea('Modo: servidor de red (puerto 3000 abierto para los demás equipos)')
      else
        RTF := RTF + RtfLinea('Modo: prueba local (todo en este equipo, sin red)');
    end else
      RTF := RTF + RtfLinea('Modo: solo cliente, conecta a: ' + Url);
    RTF := RTF + RtfLinea('Servidor: ' + Url);
    RTF := RTF + RtfLinea('Primeros pasos: abra VIGÍA y siga el asistente inicial');
    RTF := RTF + RtfLinea('Si Windows SmartScreen avisa: «Más información» → «Ejecutar de todas formas» (ver LEEME)');
    RTF := RTF + '}';
    WizardForm.FinishedLabel.RTFText := RTF;
    if not FijoFinal then begin
      WizardForm.FinishedLabel.Height := WizardForm.FinishedLabel.Height + ScaleY(64);
      WizardForm.RunList.Top := WizardForm.RunList.Top + ScaleY(64);
      WizardForm.RunList.Height := WizardForm.RunList.Height - ScaleY(64);
      FijoFinal := True;
    end;
  end;
end;


function RtfLinea(const S: string): string;
var T: string;
begin
  T := S;
  StringChangeEx(T, '\', '\\', True);
  StringChangeEx(T, '{', '\{', True);
  StringChangeEx(T, '}', '\}', True);
  Result := '\bullet  ' + T + '\line ';
end;

function JsonEscape(const S: string): string;
begin
  Result := S;
  StringChangeEx(Result, '\', '\\', True);
  StringChangeEx(Result, '"', '\"', True);
end;


procedure DeinitializeSetup;
begin
  MusicaParar;
  if ObsoletosLista <> nil then
    ObsoletosLista.Free;
end;
