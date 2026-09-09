# Fastlane and its plugins. No Gemfile.lock is committed, so every
# `bundle install` resolves the newest gem the constraint below allows. Commit
# a lock if a release ever has to be reproducible down to the fastlane build.
#
#   gem install bundler
#   bundle install
#   cd android && bundle exec fastlane lanes
source "https://rubygems.org"

gem "fastlane", "~> 2.220"

plugins_path = File.join(File.dirname(__FILE__), "android", "fastlane", "Pluginfile")
eval_gemfile(plugins_path) if File.exist?(plugins_path)
