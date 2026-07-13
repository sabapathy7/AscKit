#!/usr/bin/env ruby
# frozen_string_literal: true
#
# setup-iap.rb — Create and fully configure a non-consumable In-App Purchase
# via the App Store Connect API v2 (inAppPurchases endpoints). Idempotent:
# safe to re-run; each step skips itself if already done.
#
# Steps:
#   1. Look up the app by bundle id
#   2. Create the IAP (default type: NON_CONSUMABLE)
#   3. Add a localization for the primary locale (or IAP_LOCALE override)
#   4. Set a price schedule (base territory + price, other territories derived)
#   5. Set availability to every ASC territory (with "available in new
#      territories going forward" turned on)
#   6. Upload the App Review screenshot
#
# No gems required — stdlib only (openssl / net-http / json / base64 / digest).
#
# Usage:  ruby Scripts/setup-iap.rb
# Reads ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH plus all IAP_* variables
# from Scripts/.asc.env if they aren't already exported in the environment.
#
# Required env:
#   ASC_BUNDLE_ID          the app's bundle identifier
#   IAP_PRODUCT_ID         the IAP product identifier (must exactly match the
#                          hard-coded string in your Swift code)
#   IAP_SCREENSHOT         absolute path to the App Review screenshot PNG
#
# Optional env (with defaults):
#   IAP_TYPE               NON_CONSUMABLE (also: CONSUMABLE, NON_RENEWING_SUBSCRIPTION)
#   IAP_REF_NAME           internal reference name (default derived from PRODUCT_ID)
#   IAP_DISPLAY_NAME       max 30 chars, shown to users
#   IAP_DESCRIPTION        max 55 chars, shown to users under the localization step
#   IAP_REVIEW_NOTE        free-form notes for App Review
#   IAP_PRICE              customer price (e.g. "4.99")
#   IAP_PRICE_TERRITORY    3-letter territory for the base price (default "USA")
#   IAP_LOCALE             locale for the localization step (default: app's primaryLocale)

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

BUNDLE_ID    = ENV.fetch("ASC_BUNDLE_ID")     { abort("Set ASC_BUNDLE_ID (e.g. com.example.MyApp)") }
PRODUCT_ID   = ENV.fetch("IAP_PRODUCT_ID")    { abort("Set IAP_PRODUCT_ID (e.g. com.example.MyApp.pro.fullaccess)") }
SCREENSHOT   = ENV.fetch("IAP_SCREENSHOT")    { abort("Set IAP_SCREENSHOT to an absolute PNG path") }

IAP_TYPE     = ENV.fetch("IAP_TYPE",           "NON_CONSUMABLE")
REF_NAME     = ENV.fetch("IAP_REF_NAME",       PRODUCT_ID.split(".").last(2).join(" ").capitalize)
DISPLAY_NAME = ENV.fetch("IAP_DISPLAY_NAME",   REF_NAME)         # max 30 chars
DESCRIPTION  = ENV.fetch("IAP_DESCRIPTION",    "Premium features unlock.")  # max 55 chars
REVIEW_NOTE  = ENV.fetch("IAP_REVIEW_NOTE",
                         "One-time non-consumable purchase. See the App Review screenshot for the paywall UI. " \
                         "The paywall appears when the user attempts to access a locked feature.")
PRICE        = ENV["IAP_PRICE"]
PRICE_TERR   = ENV.fetch("IAP_PRICE_TERRITORY", "USA")
LOCALE_OVR   = ENV["IAP_LOCALE"]

# --- minimal ES256 JWT (stdlib only) ----------------------------------------

def b64url(bytes)
  Base64.urlsafe_encode64(bytes).delete("=")
end

# OpenSSL EC signatures are DER; JWT ES256 needs raw 64-byte r || s.
def der_to_raw(der)
  seq = OpenSSL::ASN1.decode(der)
  r, s = seq.value.map { |i| i.value.to_s(2) }
  [r, s].map { |v| v.rjust(32, "\x00")[-32..] }.join
end

def make_token
  now = Time.now.to_i
  header  = { alg: "ES256", kid: KEY_ID, typ: "JWT" }
  payload = { iss: ISSUER_ID, iat: now, exp: now + 1100, aud: "appstoreconnect-v1" }
  input = "#{b64url(header.to_json)}.#{b64url(payload.to_json)}"
  key = OpenSSL::PKey::EC.new(File.read(KEY_PATH))
  sig = der_to_raw(key.sign(OpenSSL::Digest.new("SHA256"), input))
  "#{input}.#{b64url(sig)}"
end

# --- tiny API client ---------------------------------------------------------

def request(method, path, body: nil, host: API_HOST, raw_body: nil, extra_headers: {})
  uri = path.start_with?("http") ? URI(path) : URI("https://#{host}#{path}")
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
  unless (200..299).cover?(code)
    abort("API #{method.upcase} #{path} failed (#{code}):\n#{raw}")
  end
  parsed
end

# --- 1. app lookup -----------------------------------------------------------

puts "==> Looking up app #{BUNDLE_ID}"
apps = api(:get, "/v1/apps?filter[bundleId]=#{BUNDLE_ID}&fields[apps]=primaryLocale,name")
abort("App not found for bundle id #{BUNDLE_ID}") if apps["data"].empty?
app = apps["data"].first
app_id = app["id"]
primary_locale = LOCALE_OVR || app.dig("attributes", "primaryLocale") || "en-US"
puts "    app id=#{app_id} locale=#{primary_locale}"

# --- 2. create (or find) the IAP ---------------------------------------------

puts "==> Ensuring IAP #{PRODUCT_ID} exists (type=#{IAP_TYPE})"
existing = api(:get, "/v1/apps/#{app_id}/inAppPurchasesV2?filter[productId]=#{PRODUCT_ID}")
if existing["data"].any?
  iap = existing["data"].first
  puts "    already exists (state=#{iap.dig('attributes', 'state')})"
else
  iap = api(:post, "/v2/inAppPurchases", body: {
    data: {
      type: "inAppPurchases",
      attributes: {
        name: REF_NAME,
        productId: PRODUCT_ID,
        inAppPurchaseType: IAP_TYPE,
        reviewNote: REVIEW_NOTE
      },
      relationships: {
        app: { data: { type: "apps", id: app_id } }
      }
    }
  })["data"]
  puts "    created id=#{iap['id']}"
end
iap_id = iap["id"]

# --- 3. localization ---------------------------------------------------------

puts "==> Ensuring localization (#{primary_locale})"
locs = api(:get, "/v2/inAppPurchases/#{iap_id}/inAppPurchaseLocalizations")
if locs["data"].any? { |l| l.dig("attributes", "locale") == primary_locale }
  puts "    already present"
else
  api(:post, "/v1/inAppPurchaseLocalizations", body: {
    data: {
      type: "inAppPurchaseLocalizations",
      attributes: { locale: primary_locale, name: DISPLAY_NAME, description: DESCRIPTION },
      relationships: {
        inAppPurchaseV2: { data: { type: "inAppPurchases", id: iap_id } }
      }
    }
  })
  puts "    created"
end

# --- 4. price schedule -------------------------------------------------------

if PRICE
  puts "==> Ensuring price schedule (#{PRICE_TERR} #{PRICE} base)"
  code, schedule, = request(:get, "/v2/inAppPurchases/#{iap_id}/iapPriceSchedule")
  if code == 200 && schedule && schedule["data"]
    puts "    already set"
  else
    points = api(:get, "/v2/inAppPurchases/#{iap_id}/pricePoints?filter[territory]=#{PRICE_TERR}&limit=200")
    point = points["data"].find { |p| p.dig("attributes", "customerPrice") == PRICE }
    unless point
      available = points["data"].map { |p| p.dig("attributes", "customerPrice") }.join(", ")
      abort("No #{PRICE_TERR} price point at #{PRICE}. Available prices: #{available}")
    end
    api(:post, "/v1/inAppPurchasePriceSchedules", body: {
      data: {
        type: "inAppPurchasePriceSchedules",
        relationships: {
          inAppPurchase: { data: { type: "inAppPurchases", id: iap_id } },
          baseTerritory: { data: { type: "territories", id: PRICE_TERR } },
          manualPrices: { data: [{ type: "inAppPurchasePrices", id: "${price-1}" }] }
        }
      },
      included: [
        {
          id: "${price-1}",
          type: "inAppPurchasePrices",
          attributes: { startDate: nil },
          relationships: {
            inAppPurchaseV2: { data: { type: "inAppPurchases", id: iap_id } },
            inAppPurchasePricePoint: { data: { type: "inAppPurchasePricePoints", id: point["id"] } }
          }
        }
      ]
    })
    puts "    set: #{PRICE} (#{PRICE_TERR} base; Apple derives all other territories)"
  end
else
  puts "==> Skipping price schedule (IAP_PRICE not set — configure it in the ASC UI or re-run with IAP_PRICE)"
end

# --- 5. availability ---------------------------------------------------------

puts "==> Ensuring availability (all territories)"
code, avail, = request(:get, "/v2/inAppPurchases/#{iap_id}/inAppPurchaseAvailability")
if code == 200 && avail && avail["data"]
  puts "    already set"
else
  territories = []
  url = "/v1/territories?limit=200"
  loop do
    page = api(:get, url)
    territories.concat(page["data"].map { |t| t["id"] })
    nxt = page.dig("links", "next")
    break unless nxt
    url = nxt.sub("https://#{API_HOST}", "")
  end
  api(:post, "/v1/inAppPurchaseAvailabilities", body: {
    data: {
      type: "inAppPurchaseAvailabilities",
      attributes: { availableInNewTerritories: true },
      relationships: {
        inAppPurchase: { data: { type: "inAppPurchases", id: iap_id } },
        availableTerritories: {
          data: territories.map { |t| { type: "territories", id: t } }
        }
      }
    }
  })
  puts "    set: #{territories.length} territories"
end

# --- 6. review screenshot ----------------------------------------------------

puts "==> Ensuring App Review screenshot"
abort("Screenshot not found: #{SCREENSHOT}") unless File.exist?(SCREENSHOT)
code, shot, = request(:get, "/v2/inAppPurchases/#{iap_id}/appStoreReviewScreenshot")
if code == 200 && shot && shot["data"]
  puts "    already uploaded (use Scripts/replace-iap-screenshot.rb to overwrite)"
else
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
    abort("Screenshot chunk upload failed (#{code2}): #{raw2}") unless (200..299).cover?(code2)
  end

  api(:patch, "/v1/inAppPurchaseAppStoreReviewScreenshots/#{reservation['id']}", body: {
    data: {
      type: "inAppPurchaseAppStoreReviewScreenshots",
      id: reservation["id"],
      attributes: { uploaded: true, sourceFileChecksum: Digest::MD5.hexdigest(bytes) }
    }
  })
  puts "    uploaded #{File.basename(SCREENSHOT)} (#{bytes.bytesize} bytes)"
end

# --- final state -------------------------------------------------------------

final = api(:get, "/v2/inAppPurchases/#{iap_id}")
state = final.dig("data", "attributes", "state")
puts ""
puts "Done. IAP state: #{state}"
puts "Expected: READY_TO_SUBMIT"
puts ""
puts "Next step (UI-only for a FIRST IAP submission):"
puts "  Open App Store Connect -> your app -> the editable version -> 'In-App"
puts "  Purchases and Subscriptions' section -> select this IAP -> Save. Then"
puts "  submit the version. See docs/IAP.md for why this checkbox cannot be"
puts "  automated via the public API."
