#!/usr/bin/env ruby
# frozen_string_literal: true
#
# check-screenshots.rb — list App Store screenshot sets per locale / display
# type for the editable app version. Handy after an `upload_screenshots` run
# to confirm the images landed in the slots you expected.
#
# Usage:  ruby Scripts/check-screenshots.rb
# Reads ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH from Scripts/.asc.env if
# they aren't already exported in the environment.
#
# Required env:
#   ASC_BUNDLE_ID    the app's bundle identifier (e.g. com.example.MyApp)
#
# Optional env:
#   ASC_VERSION_LIMIT how many app store versions to inspect (default: 5)
#
# No gems required — stdlib only.

require "openssl"
require "net/http"
require "json"
require "base64"
require "uri"

env_path = File.expand_path(".asc.env", __dir__)
if File.exist?(env_path)
  File.foreach(env_path) do |line|
    line = line.strip
    next if line.empty? || line.start_with?("#")
    k, _, v = line.partition("=")
    ENV[k.strip] ||= v.strip
  end
end

KEY_ID, ISSUER_ID, KEY_PATH = ENV.values_at("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_PATH")
BUNDLE_ID = ENV.fetch("ASC_BUNDLE_ID") { abort("Set ASC_BUNDLE_ID (e.g. com.example.MyApp) in env or Scripts/.asc.env") }
VERSION_LIMIT = Integer(ENV.fetch("ASC_VERSION_LIMIT", "5"))

abort("ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH not set") unless KEY_ID && ISSUER_ID && KEY_PATH
abort("Key file not found: #{KEY_PATH}") unless File.exist?(KEY_PATH)

def b64url(b) = Base64.urlsafe_encode64(b).delete("=")

def der_to_raw(der)
  seq = OpenSSL::ASN1.decode(der)
  seq.value.map { |i| i.value.to_s(2).rjust(32, "\x00")[-32..] }.join
end

def token
  now = Time.now.to_i
  input = "#{b64url({ alg: 'ES256', kid: KEY_ID, typ: 'JWT' }.to_json)}." \
          "#{b64url({ iss: ISSUER_ID, iat: now, exp: now + 1100, aud: 'appstoreconnect-v1' }.to_json)}"
  key = OpenSSL::PKey::EC.new(File.read(KEY_PATH))
  "#{input}.#{b64url(der_to_raw(key.sign(OpenSSL::Digest.new('SHA256'), input)))}"
end

def api(path)
  uri = URI("https://api.appstoreconnect.apple.com#{path}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  req = Net::HTTP::Get.new(uri)
  req["Authorization"] = "Bearer #{token}"
  res = http.request(req)
  abort("GET #{path} -> #{res.code}\n#{res.body}") unless res.code.to_i == 200
  JSON.parse(res.body)
end

apps = api("/v1/apps?filter[bundleId]=#{BUNDLE_ID}")
abort("App not found for bundle id #{BUNDLE_ID}") if apps["data"].empty?
app = apps["data"].first

versions = api("/v1/apps/#{app['id']}/appStoreVersions?limit=#{VERSION_LIMIT}")["data"]
versions.each do |v|
  a = v["attributes"]
  puts "Version #{a['versionString']} (#{a['appStoreState']})"
end

editable_states = %w[
  REJECTED DEVELOPER_REJECTED PREPARE_FOR_SUBMISSION METADATA_REJECTED WAITING_FOR_REVIEW
]
version = versions.find { |v| editable_states.include?(v.dig("attributes", "appStoreState")) } || versions.first
abort("No app store versions found for #{BUNDLE_ID}") unless version

locs = api("/v1/appStoreVersions/#{version['id']}/appStoreVersionLocalizations")["data"]
locs.each do |loc|
  puts "\nLocale: #{loc.dig('attributes', 'locale')}"
  sets = api("/v1/appStoreVersionLocalizations/#{loc['id']}/appScreenshotSets?limit=50")["data"]
  if sets.empty?
    puts "  (no screenshot sets)"
    next
  end
  sets.each do |set|
    shots = api("/v1/appScreenshotSets/#{set['id']}/appScreenshots?limit=50")["data"]
    states = shots.map { |s| s.dig("attributes", "assetDeliveryState", "state") }.tally
    puts "  #{set.dig('attributes', 'screenshotDisplayType')}: #{shots.length} screenshot(s) #{states}"
  end
end
