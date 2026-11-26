import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Plan de arranque del servidor integrado (solo plataforma Windows).
class LocalRuntimePlan {
  const LocalRuntimePlan({
    required this.baseDir,
    required this.pgBin,
    required this.nodeExe,
    required this.apiEntry,
    required this.sqlCatalogo,
    required this.puertoApi,
    required this.puertoBd,
  });

  final String baseDir;
  final String pgBin;
  final String nodeExe;
  final String apiEntry;
  final String sqlCatalogo;
  final int puertoApi;
  final int puertoBd;

  String get serverUrl => 'http://127.0.0.1:$puertoApi';
}

const String _dbUser = 'lexair';
const String _dbName = 'lexair_geo';
const String _jwtSecret =
    'lexair-demo-secret-2026-minint-villa-clara-0123456789';
const String _adminUser = 'yolexis';
const String _adminPassword = '123k20@A';

/// Configuración local opcional del servidor integrado
/// (%LOCALAPPDATA%\VIGIA\servidor-local.json): { "puertoApi": 3000,
/// "puertoBD": 5433, "usuarioAdmin": "...", "claveAdmin": "..." }.
Map<String, dynamic> _configLocal() {
  try {
    final local = Platform.environment['LOCALAPPDATA'];
    if (local != null) {
      final f = File('$local\\VIGIA\\servidor-local.json');
      if (f.existsSync()) {
        final dec = jsonDecode(f.readAsStringSync());
        if (dec is Map<String, dynamic>) return dec;
      }
    }
  } catch (_) {}
  return const {};
}

(int, int) _puertosConfigurados(Map<String, dynamic> cfg) {
  final api = (cfg['puertoApi'] as num?)?.toInt() ?? 3000;
  final bd = (cfg['puertoBD'] as num?)?.toInt() ?? 5433;
  return (api.clamp(1024, 65000), bd.clamp(1024, 65000));
}

/// ¿Hay un PostgreSQL respondiendo en ese puerto? (puede ser una copia
/// anterior nuestra que sigue viva: se reutiliza en vez de fallar).
Future<bool> _pgListo(int port) async {
  return _esperarPuerto(port, const Duration(milliseconds: 1200));
}

Future<bool> _puertoLibre(int port) async {
  try {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    await s.close();
    return true;
  } catch (_) {
    return false;
  }
}

/// Guarda la configuración local del modo integrado (puertos fijos y cuenta
/// inicial). Con valor null se elimina esa clave del fichero.
Future<void> guardarConfigLocal({
  int? puertoApi,
  int? puertoBd,
  String? usuarioAdmin,
  String? claveAdmin,
}) async {
  final local = Platform.environment['LOCALAPPDATA'];
  if (local == null) return;
  final dir = Directory('$local\\VIGIA');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final f = File('$local\\VIGIA\\servidor-local.json');
  Map<String, dynamic> actual = const {};
  if (f.existsSync()) {
    try {
      final d = jsonDecode(f.readAsStringSync());
      if (d is Map<String, dynamic>) actual = d;
    } catch (_) {}
  }
  void set(String k, String? v, int? n) {
    if (n != null) {
      actual[k] = n;
    } else if (v != null && v.trim().isNotEmpty) {
      actual[k] = v.trim();
    } else {
      actual.remove(k);
    }
  }

  set('puertoApi', null, puertoApi);
  set('puertoBd', null, puertoBd);
  set('usuarioAdmin', usuarioAdmin, null);
  set('claveAdmin', claveAdmin, null);
  const enc = JsonEncoder.withIndent('  ');
  await f.writeAsString(enc.convert(actual));
}

/// Detecta el paquete del servidor integrado junto al ejecutable.
Future<LocalRuntimePlan?> detectServidorIntegrado() async {
  if (!Platform.isWindows) return null;
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final base = '$exeDir\\servidor';
  final pgBin = '$base\\pg\\bin';
  final plan = LocalRuntimePlan(
    baseDir: base,
    pgBin: pgBin,
    nodeExe: '$base\\node\\node.exe',
    apiEntry: '$base\\api\\dist\\index.js',
    sqlCatalogo: '$base\\sql\\cargar_catalogo.sql',
    puertoApi: 3000,
    puertoBd: 5433,
  );
  if (!File('$pgBin\\initdb.exe').existsSync()) return null;
  if (!File('$base\\node\\node.exe').existsSync()) return null;
  if (!File(plan.apiEntry).existsSync()) return null;
  return plan;
}

/// Arranca toda la pila integrada. Idempotente y con registro.
/// [onPaso] notifica ('bd'|'esquema'|'catalogo'|'cuenta'|'api', estado) con
/// estado en {'iniciando','listo','omitido','error'}; [onLog] el detalle.
Future<LocalRuntimePlan?> ensureServidorIntegrado({
  void Function(String)? onLog,
  void Function(String paso, String estado)? onPaso,
}) async {
  final base = await detectServidorIntegrado();
  if (base == null) return null;
  void log(String m) => onLog?.call(m);
  final completados = <String>{};
  void paso(String k, String e) {
    if (e == 'listo' || e == 'omitido') completados.add(k);
    onPaso?.call(k, e);
  }

  // ¿Hay un servidor nuestro ya activo (por ejemplo arrancado antes)?
  final cfg = _puertosConfigurados(_configLocal());
  if (await _apiOk('http://127.0.0.1:${cfg.$1}')) {
    log('Servidor integrado ya activo en el puerto ${cfg.$1}');
    return LocalRuntimePlan(
      baseDir: base.baseDir, pgBin: base.pgBin, nodeExe: base.nodeExe,
      apiEntry: base.apiEntry, sqlCatalogo: base.sqlCatalogo,
      puertoApi: cfg.$1, puertoBd: cfg.$2,
    );
  }

  // Elección de puertos: configurado → siguientes. Un puerto ocupado por
  // UNA COPIA NUESTRA (base o servidor ya iniciados) se reutiliza; los que
  // ocupa otra aplicación se saltan.
  log('Buscando puertos libres (API desde ${cfg.$1}, base desde ${cfg.$2})…');
  var puertoApi = -1;
  var reusarApi = false;
  for (var p = cfg.$1; p <= cfg.$1 + 25; p++) {
    if (await _puertoLibre(p)) {
      puertoApi = p;
      break;
    }
    if (await _apiOk('http://127.0.0.1:$p')) {
      puertoApi = p;
      reusarApi = true;
      break;
    }
  }
  if (puertoApi < 0) throw Exception('No hay puertos libres para el servidor');
  var puertoBd = -1;
  var reusarBd = false;
  for (var p = cfg.$2; p <= cfg.$2 + 25; p++) {
    if (await _puertoLibre(p)) {
      puertoBd = p;
      break;
    }
    if (await _pgListo(p)) {
      puertoBd = p;
      reusarBd = true;
      break;
    }
  }
  if (puertoBd < 0) throw Exception('No hay puertos libres para la base de datos');
  if (reusarApi || reusarBd) {
    log('Reutilizando servicios ya en marcha (API $puertoApi, base $puertoBd)…');
  } else if (puertoApi != cfg.$1 || puertoBd != cfg.$2) {
    log('Puerto configurado ocupado por otra aplicación: se usará API $puertoApi y base $puertoBd');
  }

  final plan = LocalRuntimePlan(
    baseDir: base.baseDir, pgBin: base.pgBin, nodeExe: base.nodeExe,
    apiEntry: base.apiEntry, sqlCatalogo: base.sqlCatalogo,
    puertoApi: puertoApi, puertoBd: puertoBd,
  );

  final local = Platform.environment['LOCALAPPDATA'] ?? '${plan.baseDir}\\datos';
  final dataDir = '$local\\VIGIA\\datos';
  final logDir = '$local\\VIGIA\\logs';
  Directory(dataDir).createSync(recursive: true);
  Directory(logDir).createSync(recursive: true);
  final dbUrl = 'postgres://$_dbUser@127.0.0.1:$puertoBd/$_dbName';
  final env = {
    ...Platform.environment,
    'PGPORT': '$puertoBd',
    'PGHOST': '127.0.0.1',
    'PGUSER': _dbUser,
    'PGDATABASE': _dbName,
    'PGCLIENTENCODING': 'UTF8',
  };

  try {
    // 1 · Inicializar el clúster la primera vez.
    paso('bd', 'iniciando');
    if (!File('$dataDir\\PG_VERSION').existsSync()) {
      log('Inicializando base de datos local (solo la primera vez)…');
      final r = _run('${plan.pgBin}\\initdb.exe',
          ['-D', dataDir, '-U', _dbUser, '-A', 'trust', '-E', 'UTF8', '--locale=C']);
      if (r.exitCode != 0) throw Exception('initdb falló: ${_tail(r)}');
    }

    // 2 · Levantar PostgreSQL.
    log('Iniciando base de datos local (puerto $puertoBd)…');
    await Process.start(
      '${plan.pgBin}\\pg_ctl.exe',
      ['-D', dataDir, '-o', '-p $puertoBd', '-l', '$logDir\\postgresql.log', '-w', 'start'],
      environment: env,
      mode: ProcessStartMode.detached,
    );
    if (!await _esperarPuerto(puertoBd, const Duration(seconds: 60))) {
      throw Exception('La base de datos no abrió el puerto $puertoBd (ver $logDir)');
    }

    // 3 · Base de datos + extensiones.
    final hayDb = _run('${plan.pgBin}\\psql.exe',
            ['-h', '127.0.0.1', '-p', '$puertoBd', '-U', _dbUser, '-d', 'postgres', '-tAc',
             "SELECT 1 FROM pg_database WHERE datname='$_dbName'"])
        .stdout
        .toString()
        .trim();
    if (hayDb != '1') {
      log('Creando base de datos…');
      final r = _run('${plan.pgBin}\\createdb.exe',
          ['-h', '127.0.0.1', '-p', '$puertoBd', '-U', _dbUser, _dbName]);
      if (r.exitCode != 0) throw Exception('createdb falló: ${_tail(r)}');
    }
    final extOut = _run('${plan.pgBin}\\psql.exe',
            ['-h', '127.0.0.1', '-p', '$puertoBd', '-U', _dbUser, '-d', _dbName, '-tAc',
             "SELECT count(*) FROM pg_extension WHERE extname IN ('postgis','pg_trgm','unaccent')"])
        .stdout
        .toString()
        .trim();
    if (int.tryParse(extOut) == null || int.parse(extOut) < 3) {
      log('Instalando extensiones geográficas…');
      final r = _run('${plan.pgBin}\\psql.exe',
          ['-h', '127.0.0.1', '-p', '$puertoBd', '-U', _dbUser, '-d', _dbName, '-c',
           'CREATE EXTENSION IF NOT EXISTS postgis; CREATE EXTENSION IF NOT EXISTS pg_trgm; CREATE EXTENSION IF NOT EXISTS unaccent;']);
      if (r.exitCode != 0) throw Exception('Extensiones fallaron: ${_tail(r)}');
    }
    paso('bd', 'listo');

    // 4 · Migraciones.
    paso('esquema', 'iniciando');
    log('Aplicando esquema y migraciones…');
    final mig = _run(plan.nodeExe, ['api/dist/cli/migrate.js'],
        workingDirectory: plan.baseDir,
        env: {...env, 'DATABASE_URL': dbUrl, 'JWT_SECRET': _jwtSecret, 'NODE_ENV': 'production'});
    if (mig.exitCode != 0) throw Exception('Migraciones fallaron: ${_tail(mig)}');
    paso('esquema', 'listo');

    // 5 · Catálogo del territorio (si está vacío).
    paso('catalogo', 'iniciando');
    final munis = _run('${plan.pgBin}\\psql.exe',
            ['-h', '127.0.0.1', '-p', '$puertoBd', '-U', _dbUser, '-d', _dbName, '-tAc',
             'SELECT count(*) FROM geo.municipalities'])
        .stdout
        .toString()
        .trim();
    if (munis == '0') {
      log('Cargando catálogo del territorio (13 municipios, calles y alias)…');
      final r = _run('${plan.pgBin}\\psql.exe',
          ['-h', '127.0.0.1', '-p', '$puertoBd', '-U', _dbUser, '-d', _dbName, '-f', plan.sqlCatalogo]);
      if (r.exitCode != 0) throw Exception('Catálogo falló: ${_tail(r)}');
    } else {
      paso('catalogo', 'omitido');
      log('Catálogo del territorio ya cargado.');
    }
    if (munis == '0') paso('catalogo', 'listo');

    // 6 · Cuenta inicial (solo si no hay usuarios).
    paso('cuenta', 'iniciando');
    final users = _run('${plan.pgBin}\\psql.exe',
            ['-h', '127.0.0.1', '-p', '$puertoBd', '-U', _dbUser, '-d', _dbName, '-tAc',
             'SELECT count(*) FROM identity.users'])
        .stdout
        .toString()
        .trim();
    if (users == '0') {
      final cfgLocal = _configLocal();
      final usuario = (cfgLocal['usuarioAdmin'] as String?)?.trim().isNotEmpty == true
          ? (cfgLocal['usuarioAdmin'] as String).trim()
          : _adminUser;
      final clave = (cfgLocal['claveAdmin'] as String?)?.trim().isNotEmpty == true
          ? (cfgLocal['claveAdmin'] as String).trim()
          : _adminPassword;
      log('Creando cuenta inicial ($usuario)…');
      final r = _run(plan.nodeExe,
          ['api/dist/cli/create-admin.js', '--username', usuario, '--allow-weak'],
          workingDirectory: plan.baseDir,
          env: {...env, 'DATABASE_URL': dbUrl, 'JWT_SECRET': _jwtSecret,
                'LEXAIR_ADMIN_PASSWORD': clave, 'NODE_ENV': 'production'});
      if (r.exitCode != 0) throw Exception('create-admin falló: ${_tail(r)}');
    } else {
      paso('cuenta', 'omitido');
    }
    if (users == '0') paso('cuenta', 'listo');

    // 7 · API (si ya responde, se reutiliza).
    paso('api', 'iniciando');
    if (reusarApi) {
      log('Servidor local ya en marcha en el puerto $puertoApi.');
    } else {
      log('Iniciando servidor local (puerto $puertoApi)…');
      await Process.start(
        plan.nodeExe,
        ['api/dist/index.js'],
        workingDirectory: plan.baseDir,
        environment: {...env, 'DATABASE_URL': dbUrl, 'JWT_SECRET': _jwtSecret,
            'NODE_ENV': 'production', 'PORT': '$puertoApi'},
        mode: ProcessStartMode.detached,
      );
      if (!await _esperarApi(plan.serverUrl, const Duration(seconds: 90))) {
        throw Exception('El servidor no respondió en ${plan.serverUrl}');
      }
    }
    paso('api', 'listo');
    log('Servidor integrado listo en ${plan.serverUrl}');
    return plan;
  } catch (e) {
    for (final k in const ['bd', 'esquema', 'catalogo', 'cuenta', 'api']) {
      // Solo los pasos que no llegaron a terminar quedan en error.
      if (!completados.contains(k)) onPaso?.call(k, 'error');
    }
    rethrow;
  }
}

ProcessResult _run(String exe, List<String> args,
    {String? workingDirectory, Map<String, String>? env}) {
  return Process.runSync(exe, args,
      workingDirectory: workingDirectory,
      environment: env,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
      runInShell: false);
}

String _tail(ProcessResult r) {
  final s = '${r.stdout}\n${r.stderr}'.trim();
  return s.length > 600 ? '…${s.substring(s.length - 600)}' : s;
}

Future<bool> _esperarPuerto(int port, Duration timeout) async {
  final fin = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(fin)) {
    try {
      final s = await Socket.connect('127.0.0.1', port, timeout: const Duration(seconds: 2));
      s.destroy();
      return true;
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
  }
  return false;
}

Future<bool> _esperarApi(String url, Duration timeout) async {
  final fin = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(fin)) {
    if (await _apiOk(url)) return true;
    await Future<void>.delayed(const Duration(milliseconds: 900));
  }
  return false;
}

Future<bool> _apiOk(String url) async {
  try {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    final req = await client.getUrl(Uri.parse('$url/health'));
    final res = await req.close().timeout(const Duration(seconds: 5));
    final ok = res.statusCode == 200;
    await res.drain<void>();
    client.close();
    return ok;
  } catch (_) {
    return false;
  }
}
