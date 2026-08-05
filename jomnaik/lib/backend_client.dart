import 'package:supabase_flutter/supabase_flutter.dart';

const _developmentDatabricksToken = String.fromEnvironment(
  'DATABRICKS_DEBUG_TOKEN',
);
const _useSupabaseGatewayAuth = bool.fromEnvironment(
  'USE_SUPABASE_API_AUTH',
  defaultValue: false,
);

/// Headers shared by JomNaik backend requests.
///
/// Beta builds send the signed-in user's Supabase access token to the JomNaik
/// gateway. The gateway verifies it and keeps the Databricks credential on
/// the server side. A debug build can instead temporarily supply a Databricks
/// bearer token when it calls the App proxy directly. That value is compiled
/// into the app and must never be supplied for a beta or production build.
Future<Map<String, String>> backendHeaders({bool json = false}) async {
  final headers = <String, String>{'Accept': 'application/json'};
  if (json) headers['Content-Type'] = 'application/json';
  if (_useSupabaseGatewayAuth) {
    final accessToken = Supabase.instance.client.auth.currentSession?.accessToken;
    if (accessToken != null && accessToken.isNotEmpty) {
      headers['Authorization'] = 'Bearer $accessToken';
    }
  } else if (_developmentDatabricksToken.isNotEmpty) {
    headers['Authorization'] = 'Bearer $_developmentDatabricksToken';
  }
  return headers;
}
