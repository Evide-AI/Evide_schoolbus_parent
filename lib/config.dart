// App configuration.
//
// The Supabase anon key is safe to ship (public, gated by RLS). The Mapbox
// PUBLIC token is also safe in the app. Never put the Supabase service-role
// key or Firebase service-account key here — those are backend-only.
class AppConfig {
  static const supabaseUrl = 'https://rujjbkvqsqzholravzsx.supabase.co';
  static const supabaseAnonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJ1ampia3Zxc3F6aG9scmF2enN4Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODkxODQwNDIsImV4cCI6MjEwNDc2MDA0Mn0.eWqDNABawNDqurD-1OWrygNNewub05PHYyCOohT53bs';

  // TODO: paste your Mapbox PUBLIC access token here (pk.****).
  // Get it from account.mapbox.com -> Tokens.
  static const mapboxPublicToken = 'pk.eyJ1IjoiZXZpZGUiLCJhIjoiY210eWVkZXMwMGh1bDJ3czNwNHRsZHAyayJ9.caH51rOo6fVJCrFB1Fh6tA';
}
