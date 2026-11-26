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
  });

  final String baseDir;
  final String pgBin;
  final String nodeExe;
  final String apiEntry;
  final String sqlCatalogo;

  String get serverUrl => 'http://127.0.0.1:3000';
}

const String _dbPort = '5433';
const String _dbUser = 'lexair';
const String _dbName = 'lexair_geo';
const String _jwtSecret =
    'lexair-demo-secret-2026-minint-villa-clara-0123456789';
const String _adminUser = 'yolexis';
const String _adminPassword = '123k20@A';

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
  );
  if (!File('$pgBin\\initdb.exe').existsSync()) return null;
  if (!File('$base\\node\\node.exe').existsSync()) return null;
  if (!File(plan.apiEntry).existsSync()) return null;
  return plan;
}

/// Arranca toda la pila integrada. Idempotente y con registro en `onLog`.
Future<LocalRuntimePlan?> ensureServidorIntegrado({
  void Function(String)? onLog,
}) async {
  final plan = await detectServidorIntegrado();
  if (plan == null) return null;
  void log(String m) => onLog?.call(m);

  // ¿El API ya responde? Nada que hacer.
  if (await _apiOk(plan.serverUrl)) {
    log('Servidor integrado ya activo en ${plan.serverUrl}');
    return plan;
  }

  final local = Platform.environment['LOCALAPPDATA'] ??
      '${plan.baseDir}\\datos';
  final dataDir = '$local\\VIGIA\\datos';
  final logDir = '$local\\VIGIA\\logs';
  Directory(dataDir).createSync(recursive: true);
  Directory(logDir).createSync(recursive: true);
  final dbUrl = 'postgres://$_dbUser@127.0.0.1:$_dbPort/$_dbName';
  final env = {
    ...Platform.environment,
    'PGPORT': _dbPort,
    'PGHOST': '127.0.0.1',
    'PGUSER': _dbUser,
    'PGDATABASE': _dbName,
    'PGCLIENTENCODING': 'UTF8',
  };

  // 1 · Inicializar el clúster la primera vez.
  if (!File('$dataDir\\PG_VERSION').existsSync()) {
    log('Inicializando base de datos local (solo la primera vez)…');
    final r = _run(
      '${plan.pgBin}\\initdb.exe',
      ['-D', dataDir, '-U', _dbUser, '-A', 'trust', '-E', 'UTF8', '--locale=C'],
    );
    if (r.exitCode != 0) {
      throw Exception('initdb falló: ${_tail(r)}');
    }
  }

  // 2 · Levantar PostgreSQL en el puerto 5433.
  log('Iniciando PostgreSQL local…');
  await Process.start(
    '${plan.pgBin}\\pg_ctl.exe',
    ['-D', dataDir, '-o', '-p $_dbPort', '-l', '$logDir\\postgresql.log', '-w', 'start'],
    environment: env,
    mode: ProcessStartMode.detached,
  );
  if (!await _esperarPuerto(int.parse(_dbPort), const Duration(seconds: 60))) {
    throw Exception('PostgreSQL no abrió el puerto $_dbPort (ver $logDir)');
  }

  // 3 · Base de datos + extensiones.
  final hayDb = _run('${plan.pgBin}\\psql.exe',
          ['-h', '127.0.0.1', '-p', _dbPort, '-U', _dbUser, '-d', 'postgres', '-tAc',
           "SELECT 1 FROM pg_database WHERE datname='$_dbName'"])
      .stdout
      .trim();
  if (hayDb != '1') {
    log('Creando base de datos $_dbName…');
    final r = _run('${plan.pgBin}\\createdb.exe',
        ['-h', '127.0.0.1', '-p', _dbPort, '-U', _dbUser, _dbName]);
    if (r.exitCode != 0) throw Exception('createdb falló: ${_tail(r)}');
  }
  final ext = _run('${plan.pgBin}\\psql.exe',
      ['-h', '127.0.0.1', '-p', _dbPort, '-U', _dbUser, '-d', _dbName, '-tAc',
       "SELECT count(*) FROM pg_extension WHERE extname IN ('postgis','pg_trgm','unaccent')"]);
  final extOut = ext.stdout.toString().trim();
  if (int.tryParse(extOut) == null || int.parse(extOut) < 3) {
    log('Instalando extensiones (PostGIS…)');
    final r = _run('${plan.pgBin}\\psql.exe',
        ['-h', '127.0.0.1', '-p', _dbPort, '-U', _dbUser, '-d', _dbName, '-c',
         'CREATE EXTENSION IF NOT EXISTS postgis; CREATE EXTENSION IF NOT EXISTS pg_trgm; CREATE EXTENSION IF NOT EXISTS unaccent;']);
    if (r.exitCode != 0) throw Exception('Extensiones fallaron: ${_tail(r)}');
  }

  // 4 · Migraciones.
  log('Aplicando esquema y migraciones…');
  final mig = _run(plan.nodeExe, ['api/dist/cli/migrate.js'],
      workingDirectory: plan.baseDir,
      env: {...env, 'DATABASE_URL': dbUrl, 'JWT_SECRET': _jwtSecret, 'NODE_ENV': 'production'});
  if (mig.exitCode != 0) throw Exception('Migraciones fallaron: ${_tail(mig)}');

  // 5 · Catálogo geográfico de Villa Clara (si está vacío).
  final munis = _run('${plan.pgBin}\\psql.exe',
      ['-h', '127.0.0.1', '-p', _dbPort, '-U', _dbUser, '-d', _dbName, '-tAc',
       'SELECT count(*) FROM geo.municipalities']);
  if (munis.stdout.trim() == '0') {
    log('Cargando catálogo de Villa Clara (13 municipios, calles y alias)…');
    final r = _run('${plan.pgBin}\\psql.exe',
        ['-h', '127.0.0.1', '-p', _dbPort, '-U', _dbUser, '-d', _dbName, '-f', plan.sqlCatalogo]);
    if (r.exitCode != 0) throw Exception('Catálogo falló: ${_tail(r)}');
  } else {
    log('Catálogo geográfico ya cargado.');
  }

  // 6 · Administrador inicial (solo si no hay usuarios).
  final users = _run('${plan.pgBin}\\psql.exe',
      ['-h', '127.0.0.1', '-p', _dbPort, '-U', _dbUser, '-d', _dbName, '-tAc',
       'SELECT count(*) FROM identity.users']);
  if (users.stdout.trim() == '0') {
    log('Creando administrador inicial ($_adminUser)…');
    final r = _run(plan.nodeExe,
        ['api/dist/cli/create-admin.js', '--username', _adminUser, '--allow-weak'],
        workingDirectory: plan.baseDir,
        env: {...env, 'DATABASE_URL': dbUrl, 'JWT_SECRET': _jwtSecret,
              'LEXAIR_ADMIN_PASSWORD': _adminPassword, 'NODE_ENV': 'production'});
    if (r.exitCode != 0) throw Exception('create-admin falló: ${_tail(r)}');
  }

  // 7 · API en el puerto 3000.
  log('Iniciando servidor VIGÍA (API)…');
  await Process.start(
    plan.nodeExe,
    ['api/dist/index.js'],
    workingDirectory: plan.baseDir,
    environment: {...env, 'DATABASE_URL': dbUrl, 'JWT_SECRET': _jwtSecret,
        'NODE_ENV': 'production', 'PORT': '3000'},
    mode: ProcessStartMode.detached,
  );
  if (!await _esperarApi(plan.serverUrl, const Duration(seconds: 90))) {
    throw Exception('El API no respondió en ${plan.serverUrl}');
  }
  log('Servidor integrado listo en ${plan.serverUrl}');
  return plan;
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
