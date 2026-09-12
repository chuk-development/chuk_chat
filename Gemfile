# Fastlane, for every platform. This is the only Gemfile in the repository:
# bundler walks up from the working directory, so `bundle exec fastlane` finds
# it from android/, linux/ and macos/ alike. There used to be one per platform,
# which meant three unlocked dependency sets and a plugin
# (fastlane-plugin-flutter_version) that no Fastfile ever called.
#
# Gemfile.lock is committed, so a local run and a CI run use the same versions.
#
#   gem install bundler
#   bundle install
#   cd android && bundle exec fastlane lanes
source "https://rubygems.org"

gem "fastlane", "~> 2.220"

plugins_path = File.join(File.dirname(__FILE__), "android", "fastlane", "Pluginfile")
eval_gemfile(plugins_path) if File.exist?(plugins_path)
