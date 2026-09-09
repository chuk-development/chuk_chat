# Shared by android/, linux/ and macos/ Fastfiles.
#
# Every release build reads its Supabase credentials with
# `--dart-define-from-file=.env`. Hand-rolled `--dart-define=SUPABASE_*` is what
# the repository rules forbid, because one missing value produces a binary that
# boots to "Supabase credentials are not configured" — and nothing fails until
# somebody starts the app, long after the build.
module EnvGuard
  REQUIRED = %w[SUPABASE_URL SUPABASE_ANON_KEY].freeze

  # Absolute path of the repository's .env. Raises through fastlane's UI if the
  # file is missing or if a required key carries no value.
  def self.env_file!
    path = File.expand_path("../.env", __dir__)

    unless File.exist?(path)
      UI.user_error!(
        "No .env at the repository root. Copy .env.example and fill in the " \
        "Supabase credentials."
      )
    end

    missing = REQUIRED - present_keys(path)
    UI.user_error!("#{path} has no value for: #{missing.join(', ')}") unless missing.empty?

    path
  end

  # Keys that carry a non-empty value. `KEY=`, `KEY=""` and `# KEY=x` all count
  # as absent.
  def self.present_keys(path)
    File.readlines(path, chomp: true).filter_map do |line|
      match = line.strip.match(/\A([A-Z0-9_]+)\s*=\s*(.*)\z/)
      next unless match

      value = match[2].strip.sub(/\A(['"])(.*)\1\z/, '\2').strip
      match[1] unless value.empty?
    end
  end
end
