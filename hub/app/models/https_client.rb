require "net/http"

# Select the proxy for the HTTPS destination and bound connection and read times.
class HttpsClient
  def self.for(uri)
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
    client
  end
end
