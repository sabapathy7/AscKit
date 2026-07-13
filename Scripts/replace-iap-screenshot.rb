#!/usr/bin/env ruby
# frozen_string_literal: true
#
# replace-iap-screenshot.rb — Delete the existing App Review screenshot on an
# IAP (if any) and upload a fresh PNG. Companion to setup-iap.rb, which skips
# the screenshot step once one is already uploaded.
#
# Usage:  ruby Scripts/replace-iap-screenshot.rb
#
# Required env:
#   ASC_BUNDLE_ID      the app's bundle identifier
#   IAP_PRODUCT_ID     the IAP product identifier
#   IAP_SCREENSHOT     absolute path to the replacement PNG
#
# No gems required — stdlib only.

require "openssl"
require "net/http"
require "json"
require "base64"
require "digest"
require "uri"

API_HOST = "api.appstoreconnect.apple.com"

env_path = File.expand_path(".asc.env", __dir__)
if File.exist?(env_path)
  File.foreach(env_path) do |line|
    line = line.strip
    next if line.empty? || line.start_with?("#")
    key, _, value = line.partition("=")
    ENV[key.strip] ||= value.strip
  end
end

KEY_ID, ISSUER_ID, KEY_PATH = ENV.values_at("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_PATH")
abort("ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH not set") unless KEY_ID && ISSUER_ID && KEY_PATH
abort("Key file not found: #{KEY_PATH}") unless File.exist?(KEY_PATH)

BUNDLE_ID  = ENV.fetch("ASC_BUNDLE_ID")  { abort("Set ASC_BUNDLE_ID") }
PRODUCT_ID = ENV.fetch("IAP_PRODUCT_ID") { abort("Set IAP_PRODUCT_ID") }
SCREENSHOT = ENV.fetch("IAP_SCREENSHOT") { abort("Set IAP_SCREENSHOT to an absolute PNG path") }

def b64url(bytes) = Base64.urlsafe_encode64(bytes).delete("=")

def der_to_raw(der)
  seq = OpenSSL::ASN1.decode(der)
  seq.value.map { |i| i.value.to_s(2).rjust(32, "\x00")[-32..] }.join
end

def make_token
  now = Time.now.to_i
  input = "#{b64url({ alg: 'ES256', kid: KEY_ID, typ: 'JWT' }.to_json)}." \
          "#{b64url({ iss: ISSUER_ID, iat: now, exp: now + 1100, aud: 'appstoreconnect-v1' }.to_json)}"
  key = OpenSSL::PKey::EC.new(File.read(KEY_PATH))
  "#{input}.#{b64url(der_to_raw(key.sign(OpenSSL::Digest.new('SHA256'), input)))}"
end

def request(method, path, body: nil, raw_body: nil, extra_headers: {})
  uri = path.start_with?("http") ? URI(path) : URI("https://#{API_HOST}#{path}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  req = Net::HTTP.const_get(method.capitalize).new(uri)
  req["Authorization"] = "Bearer #{make_token}" if uri.host == API_HOST
  if raw_body
    req.body = raw_body
  elsif body
    req["Content-Type"] = "application/json"
    req.body = JSON.generate(body)
  end
  extra_headers.each { |k, v| req[k] = v }
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
apps = api(:get, "/v1/apps?filter[bundleId]=#{BUNDLE_ID}")
abort("App not found") if apps["data"].empty?
app_id = apps["data"].first["id"]

puts "==> Looking up IAP #{PRODUCT_ID}"
existing = api(:get, "/v1/apps/#{app_id}/inAppPurchasesV2?filter[productId]=#{PRODUCT_ID}")
abort("IAP not found — run setup-iap.rb first") if existing["data"].empty?
iap_id = existing["data"].first["id"]

puts "==> Checking for existing review screenshot"
code, shot, = request(:get, "/v2/inAppPurchases/#{iap_id}/appStoreReviewScreenshot")
if code == 200 && shot && shot["data"]
  shot_id = shot["data"]["id"]
  puts "    deleting existing screenshot #{shot_id}"
  dcode, _, draw = request(:delete, "/v1/inAppPurchaseAppStoreReviewScreenshots/#{shot_id}")
  abort("Delete failed (#{dcode}): #{draw}") unless (200..299).cover?(dcode)
else
  puts "    none present"
end

puts "==> Uploading #{File.basename(SCREENSHOT)}"
abort("Screenshot not found: #{SCREENSHOT}") unless File.exist?(SCREENSHOT)
bytes = File.binread(SCREENSHOT)
reservation = api(:post, "/v1/inAppPurchaseAppStoreReviewScreenshots", body: {
  data: {
    type: "inAppPurchaseAppStoreReviewScreenshots",
    attributes: { fileName: File.basename(SCREENSHOT), fileSize: bytes.bytesize },
    relationships: {
      inAppPurchaseV2: { data: { type: "inAppPurchases", id: iap_id } }
    }
  }
})["data"]

reservation.dig("attributes", "uploadOperations").each do |op|
  headers = (op["requestHeaders"] || []).to_h { |h| [h["name"], h["value"]] }
  chunk = bytes[op["offset"], op["length"]]
  code2, _, raw2 = request(op["method"].downcase.to_sym, op["url"], raw_body: chunk, extra_headers: headers)
  abort("Chunk upload failed (#{code2}): #{raw2}") unless (200..299).cover?(code2)
end

api(:patch, "/v1/inAppPurchaseAppStoreReviewScreenshots/#{reservation['id']}", body: {
  data: {
    type: "inAppPurchaseAppStoreReviewScreenshots",
    id: reservation["id"],
    attributes: { uploaded: true, sourceFileChecksum: Digest::MD5.hexdigest(bytes) }
  }
})
puts "    uploaded (#{bytes.bytesize} bytes)"

final = api(:get, "/v2/inAppPurchases/#{iap_id}")
puts ""
puts "Done. IAP state: #{final.dig('data', 'attributes', 'state')}"
