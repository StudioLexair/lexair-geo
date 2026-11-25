import 'config/app_config.dart';
import 'config/config_store.dart';
import 'net/api_client.dart';

/// Dependencias de larga vida compartidas por toda la aplicación.
class AppServices {
  AppServices({required this.config, required this.api, required this.configStore});

  final AppConfig config;
  final ApiClient api;
  final ConfigStore configStore;
}
