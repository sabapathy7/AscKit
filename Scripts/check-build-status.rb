#!/usr/bin/env ruby
# frozen_string_literal: true
#
# check-build-status.rb — list the last N builds for the app and their
# processing state (PROCESSING / VALID / INVALID / FAILED). Useful after a
# release-testflight.sh / fastlane beta upload to poll for readiness before
# running attach-build-and-submit.rb.
#
# Usage:  ruby Scripts/check-build-status.rb
#
# Required env:
#   ASC_BUNDLE_ID   the app's bundle identifier
#
# Optional env:
#   ASC_BUILD_LIMIT how many builds to list (default: 5)

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
BUNDLE_ID = ENV.fetch("ASC_BUNDLE_ID") { abort("Set ASC_BUNDLE_ID (e.g. com.example.MyApp)") }
LIMIT     = Integer(ENV.fetch("ASC_BUILD_LIMIT", "5"))

abort("ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH not set") unless KEY_ID && ISSUER_ID && KEY_PATH

def b64url(b) = Base64.urlsafe_encode64(b).delete("=")

def der_to_raw(der)
  OpenSSL::ASN1.decode(der).value.map { |i| i.value.to_s(2).rjust(32, "\x00")[-32..] }.join
end

def token
  now = Time.now.to_i
  input = "#{b64url({ alg: 'ES256', kid: ENV['ASC_KEY_ID'], typ: 'JWT' }.to_json)}." \
          "#{b64url({ iss: ENV['ASC_ISSUER_ID'], iat: now, exp: now + 1100, aud: 'appstoreconnect-v1' }.to_json)}"
  key = OpenSSL::PKey::EC.new(File.read(ENV['ASC_KEY_PATH']))
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

builds = api("/v1/apps/#{app['id']}/builds?limit=#{LIMIT}&fields[builds]=version,processingState,uploadedDate")["data"]
if builds.empty?
  puts "No builds found for #{BUNDLE_ID}"
  exit 0
end

builds.each do |b|
  a = b["attributes"]
  puts "build #{a['version']} — #{a['processingState']} (uploaded #{a['uploadedDate']})"
end
