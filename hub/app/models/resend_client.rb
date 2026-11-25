require "net/http"

# Sends one sign-in code through the configured HTTPS email endpoint.
class ResendClient
  class DeliveryError < StandardError; end

  def self.deliver!(email:, code:)
    key = ENV["RESEND_API_KEY"].presence
    if Rails.env.development? && !key
      Rails.logger.info("Development sign-in code for #{email}: #{code}")
      return
    end
    sender = ENV["RESEND_FROM_EMAIL"].presence
    raise DeliveryError, "Email sender credentials are missing" unless key && sender

    uri = URI.parse(ENV.fetch("RESEND_API_BASE_URL", "https://api.resend.com").delete_suffix("/") + "/emails")
    raise DeliveryError, "Email delivery requires HTTPS" unless uri.is_a?(URI::HTTPS)

    # Net::HTTP's default proxy discovery uses http_proxy, even for HTTPS targets.
    proxy = uri.find_proxy
    client = if proxy
      Net::HTTP.new(uri.host, uri.port, proxy.host, proxy.port, proxy.user, proxy.password, nil, proxy.scheme == "https")
    else
      Net::HTTP.new(uri.host, uri.port, nil)
    end
    client.use_ssl = true
    client.open_timeout = 5
    client.read_timeout = 10
    request = Net::HTTP::Post.new(uri, "Authorization" => "Bearer #{key}", "Content-Type" => "application/json")
    request.body = JSON.generate \
      from: sender, to: [ email ], subject: I18n.t("email_login.subject"), text: I18n.t("email_login.body", code:)
    response = client.request(request)
    raise DeliveryError, "Email delivery returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
  end
end
