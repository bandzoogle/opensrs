require "uri"
require "net/https"
require "digest/md5"
require "openssl"

module OpenSRS
  class OpenSRSError < StandardError; end

  class BadResponse < OpenSRSError; end
  class ConnectionError < OpenSRSError; end
  class TimeoutError < ConnectionError; end

  class Server
    attr_accessor :server, :username, :password, :key, :timeout, :open_timeout, :logger, :ssl_verify, :ssl_ciphers

    def initialize(options = {})
      @server   = URI.parse(options[:server] || "https://rr-n1-tor.opensrs.net:55443/")
      @username = options[:username]
      @password = options[:password]
      @key      = options[:key]
      @timeout  = options[:timeout]
      @open_timeout = options[:open_timeout]
      @logger   = options[:logger]
      @sanitize_request = options[:sanitize_request]
      @ssl_verify = options[:ssl_verify] || OpenSSL::SSL::VERIFY_NONE
      @ssl_ciphers = options[:ssl_ciphers]

      OpenSRS::SanitizableString.enable_sanitization = @sanitize_request
    end

    def call(data = {})
      xml = xml_processor.build({ :protocol => "XCP" }.merge!(data))
      log("Request", xml.sanitized, data)

      begin
        response = http.post(server_path, xml.to_s, headers(xml))
        log("Response", response.body, data)
      rescue Net::HTTPBadResponse
        raise OpenSRS::BadResponse, "Received a bad response from OpenSRS. Please check that your IP address is added to the whitelist, and try again."
      end

      parsed_response = xml_processor.parse(response.body)
      OpenSRS::Response.new(parsed_response, xml.sanitized, response.body)
    rescue Timeout::Error => err
      raise OpenSRS::TimeoutError, err
    rescue Errno::ECONNRESET, Errno::ECONNREFUSED => err
      raise OpenSRS::ConnectionError, err
    end

    def xml_processor
      @@xml_processor
    end

    def self.xml_processor=(name)
      require "opensrs/xml_processor/#{name.to_s.downcase}"
      @@xml_processor = OpenSRS::XmlProcessor.const_get("#{name.to_s.capitalize}")
    end

    private

    def headers(request)
      {
        "Content-Length"  => request.length.to_s,
        "Content-Type"    => "text/xml",
        "X-Username"      => username,
        "X-Signature"     => signature(request)
      }
    end

    def signature(request)
      Digest::MD5.hexdigest(Digest::MD5.hexdigest(request + key) + key)
    end

    def http
      http = Net::HTTP.new(server.host, server.port)
      http.use_ssl = (server.scheme == "https")
      http.verify_mode = @ssl_verify if @ssl_verify
      http.read_timeout = http.open_timeout = @timeout if @timeout
      http.open_timeout = @open_timeout                if @open_timeout
      http.ciphers = @ssl_ciphers if @ssl_ciphers
      http
    end

    def log(type, data, options = {})
      return unless logger

      message = "[OpenSRS] #{type} XML"
      message = "#{message} for #{options[:object]} #{options[:action]}" if options[:object] && options[:action]

      line = [message, data].join("\n")
      logger.info(line)
    end

    def server_path
      server.path.empty? ? '/' : server.path
    end
  end
end
