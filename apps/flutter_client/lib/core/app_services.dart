import 'config/app_config.dart';
import 'config/config_store.dart';
import '../features/persons/photo_cache.dart';
import 'net/api_client.dart';

/// Dependencias de larga vida compartidas por toda la aplicación.
class AppServices {
  AppServices({required this.config, required this.api, required this.configStore, this.onConfigChanged}) {
    PhotoCache.I.bind(api);
  }

  final AppConfig config;
  final ApiClient api;
  final ConfigStore configStore;
  final Future<void> Function()? onConfigChanged;
}
