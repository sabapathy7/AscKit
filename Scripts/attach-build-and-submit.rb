#!/usr/bin/env ruby
# frozen_string_literal: true
#
# attach-build-and-submit.rb — Attach a processed build (and optionally an IAP)
# to the app's editable App Store version, then create a review submission.
#
# Usage:
#   ruby Scripts/attach-build-and-submit.rb           # attach only; do not submit
#   ruby Scripts/attach-build-and-submit.rb --submit  # attach + create review submission
#
# Required env:
#   ASC_BUNDLE_ID       the app's bundle identifier
#   BUILD_VERSION       the build number of the .ipa to attach (e.g. "4")
#
# Optional env:
#   IAP_PRODUCT_ID      if set, also add the IAP as a review submission item.
#                       Skip this for a FIRST IAP submission (see docs/IAP.md
#                       — that specific case is UI-only in App Store Connect).
#
# No gems required — stdlib only.

require "openssl"
require "net/http"
require "json"
require "base64"
require "uri"

API_HOST = "api.appstoreconnect.apple.com"

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
abort("ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH not set") unless KEY_ID && ISSUER_ID && KEY_PATH

BUNDLE_ID    = ENV.fetch("ASC_BUNDLE_ID") { abort("Set ASC_BUNDLE_ID") }
TARGET_BUILD = ENV.fetch("BUILD_VERSION") { abort("Set BUILD_VERSION (e.g. \"4\")") }
PRODUCT_ID   = ENV["IAP_PRODUCT_ID"]
DO_SUBMIT    = ARGV.include?("--submit")

def b64url(b) = Base64.urlsafe_encode64(b).delete("=")

def der_to_raw(der)
  OpenSSL::ASN1.decode(der).value.map { |i| i.value.to_s(2).rjust(32, "\x00")[-32..] }.join
end

def make_token
  now = Time.now.to_i
  input = "#{b64url({ alg: 'ES256', kid: ENV['ASC_KEY_ID'], typ: 'JWT' }.to_json)}." \
          "#{b64url({ iss: ENV['ASC_ISSUER_ID'], iat: now, exp: now + 1100, aud: 'appstoreconnect-v1' }.to_json)}"
  key = OpenSSL::PKey::EC.new(File.read(ENV["ASC_KEY_PATH"]))
  "#{input}.#{b64url(der_to_raw(key.sign(OpenSSL::Digest.new('SHA256'), input)))}"
end

def request(method, path, body: nil)
  uri = URI("https://#{API_HOST}#{path}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  req = Net::HTTP.const_get(method.capitalize).new(uri)
  req["Authorization"] = "Bearer #{make_token}"
  if body
    req["Content-Type"] = "application/json"
    req.body = JSON.generate(body)
  end
  res = http.request(req)
  parsed = begin
    res.body && !res.body.empty? ? JSON.parse(res.body) : nil
  rescue JSON::ParserError
    nil
  end
  [res.code.to_i, parsed, res.body]
end

def api(method, path, body: nil)
  code, parsed, raw = request(method, path, body: body)
  abort("API #{method.upcase} #{path} failed (#{code}):\n#{raw}") unless (200..299).cover?(code)
  parsed
end

puts "==> Looking up app #{BUNDLE_ID}"
app_id = api(:get, "/v1/apps?filter[bundleId]=#{BUNDLE_ID}")["data"].first&.dig("id")
abort("App not found") unless app_id

puts "==> Finding editable app version"
versions = api(:get, "/v1/apps/#{app_id}/appStoreVersions?limit=5&fields[appStoreVersions]=versionString,appStoreState")["data"]
versions.each { |v| puts "    #{v.dig('attributes', 'versionString')} — #{v.dig('attributes', 'appStoreState')}" }

editable_states = %w[
  PREPARE_FOR_SUBMISSION DEVELOPER_REJECTED REJECTED
  METADATA_REJECTED INVALID_BINARY WAITING_FOR_EXPORT_COMPLIANCE
]
version = versions.find { |v| editable_states.include?(v.dig("attributes", "appStoreState")) }
abort("No editable version found (states seen: #{versions.map { |v| v.dig('attributes', 'appStoreState') }})") unless version
version_id = version["id"]
puts "==> Using version #{version.dig('attributes', 'versionString')} (#{version.dig('attributes', 'appStoreState')})"

puts "==> Finding build #{TARGET_BUILD}"
builds = api(:get, "/v1/apps/#{app_id}/builds?limit=20&fields[builds]=version,processingState")["data"]
build = builds.find { |b| b.dig("attributes", "version") == TARGET_BUILD }
abort("Build #{TARGET_BUILD} not found") unless build
processing = build.dig("attributes", "processingState")
abort("Build #{TARGET_BUILD} is not VALID yet (state=#{processing}). Wait for processing to finish.") unless processing == "VALID"
build_id = build["id"]
puts "    build id=#{build_id} state=VALID"

puts "==> Attaching build to version"
api(:patch, "/v1/appStoreVersions/#{version_id}", body: {
  data: {
    type: "appStoreVersions",
    id: version_id,
    relationships: {
      build: { data: { type: "builds", id: build_id } }
    }
  }
})
puts "    attached"

iap_id = nil
if PRODUCT_ID
  puts "==> Looking up IAP #{PRODUCT_ID}"
  iaps = api(:get, "/v1/apps/#{app_id}/inAppPurchasesV2?filter[productId]=#{PRODUCT_ID}")["data"]
  if iaps.empty?
    puts "    WARNING: IAP #{PRODUCT_ID} not found — skipping"
  else
    iap_id = iaps.first["id"]
    puts "    iap id=#{iap_id}"
    puts "    NOTE: IAPs are added to a review submission as separate items,"
    puts "    not to the version directly. See --submit below."
  end
end

if DO_SUBMIT
  puts "==> Creating review submission"
  code, sub, raw = request(:post, "/v1/reviewSubmissions", body: {
    data: {
      type: "reviewSubmissions",
      attributes: { platform: "IOS" },
      relationships: {
        app: { data: { type: "apps", id: app_id } }
      }
    }
  })
  abort("Could not create review submission (#{code}): #{raw}") unless (200..299).cover?(code)
  submission_id = sub["data"]["id"]
  puts "    created submission id=#{submission_id}"

  puts "==> Adding version item to submission"
  icode, _, iraw = request(:post, "/v1/reviewSubmissionItems", body: {
    data: {
      type: "reviewSubmissionItems",
      relationships: {
        reviewSubmission: { data: { type: "reviewSubmissions", id: submission_id } },
        appStoreVersion:  { data: { type: "appStoreVersions",  id: version_id } }
      }
    }
  })
  abort("Failed to add version to submission (#{icode}): #{iraw}") unless (200..299).cover?(icode)
  puts "    added"

  if iap_id
    puts "==> Adding IAP item to submission (subsequent submissions only)"
    # Note: the relationship's type discriminator is "inAppPurchases" even
    # though the resource itself lives at /apps/{id}/inAppPurchasesV2.
    #
    # For a FIRST-time IAP submission this call will not attach the IAP —
    # Apple's public API does not expose that path. See docs/IAP.md.
    jcode, _, jraw = request(:post, "/v1/reviewSubmissionItems", body: {
      data: {
        type: "reviewSubmissionItems",
        relationships: {
          reviewSubmission: { data: { type: "reviewSubmissions", id: submission_id } },
          inAppPurchases:   { data: { type: "inAppPurchases",    id: iap_id } }
        }
      }
    })
    if (200..299).cover?(jcode)
      puts "    added"
    else
      puts "    WARNING: could not add IAP to submission (#{jcode}): #{jraw}"
      puts "    If this is the first IAP submission, this is expected — add the"
      puts "    IAP to the version in the ASC UI, cancel this submission with:"
      puts "      PATCH /v1/reviewSubmissions/#{submission_id} { attributes: { canceled: true } }"
      puts "    and resubmit from the UI."
    end
  end

  puts "==> Submitting for review"
  scode, _, sraw = request(:patch, "/v1/reviewSubmissions/#{submission_id}", body: {
    data: {
      type: "reviewSubmissions",
      id: submission_id,
      attributes: { submitted: true }
    }
  })
  abort("Submit failed (#{scode}): #{sraw}") unless (200..299).cover?(scode)
  puts "    SUBMITTED"
else
  puts ""
  puts "Build attached. Re-run with --submit to create a review submission, or click"
  puts "'Add for Review' / 'Submit to App Review' in App Store Connect."
end
