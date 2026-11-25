import 'package:flutter/material.dart';

import 'app.dart';
import 'core/app_services.dart';
import 'core/config/config_store.dart';
import 'core/net/api_client.dart';
import 'core/net/http_client_factory.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = ConfigStore();
  final config = await store.load();
  final api = ApiClient(
    baseUrl: config.apiBase,
    client: createHttpClient(caCertificatePath: config.caCertificatePath),
  );
  runApp(LexairApp(services: AppServices(config: config, api: api, configStore: store)));
}
