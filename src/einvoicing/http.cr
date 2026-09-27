# SPDX-License-Identifier: AGPL-3.0-or-later

require "http/client"
require "http/formdata"
require "openssl"
require "uri"
require "json"
require "uuid"

module Einvoicing
  # Échanges HTTP avec les plateformes agréées, derrière un transport
  # remplaçable : le réseau réel (`NetTransport`, TLS *vérifié*) en
  # production, une plateforme simulée dans les specs (ADR-004 D6).
  #
  # `peppol-connect` désactivait la vérification TLS
  # (`CURLOPT_SSL_VERIFYPEER => false`) : ici, le contexte TLS client de
  # Crystal vérifie le certificat et le nom d'hôte, et aucun réglage ne
  # permet de l'éteindre (ADR-004 D2).
  module Http
    record Request,
      method : String,
      url : String,
      headers : Hash(String, String) = {} of String => String,
      body : Bytes? = nil

    record Response,
      status : Int32,
      headers : Hash(String, String),
      body : Bytes do
      def success? : Bool
        (200..299).includes?(status)
      end

      def text : String
        String.new(body)
      end

      def json : JSON::Any
        JSON.parse(text)
      rescue ex : JSON::ParseException
        raise ConnectorError.new("réponse JSON illisible (#{status}) : #{ex.message}", status,
          "einvoicing.errors.transport.json", {"status" => status.to_s, "detail" => ex.message.to_s})
      end
    end

    abstract class Transport
      abstract def exec(request : Request) : Response
    end

    # Réseau réel. HTTPS exigé ; certificat et nom d'hôte vérifiés.
    class NetTransport < Transport
      TIMEOUT = 60.seconds

      def self.tls_context : OpenSSL::SSL::Context::Client
        OpenSSL::SSL::Context::Client.new
      end

      def exec(request : Request) : Response
        uri = URI.parse(request.url)
        unless uri.scheme == "https"
          raise ConnectorError.new("adresse non HTTPS refusée : #{request.url}", nil, "einvoicing.errors.transport.https",
            {"url" => request.url})
        end
        client = HTTP::Client.new(uri, tls: NetTransport.tls_context)
        client.connect_timeout = TIMEOUT
        client.read_timeout = TIMEOUT
        headers = HTTP::Headers.new
        request.headers.each { |name, value| headers[name] = value }
        response = client.exec(request.method, uri.request_target, headers: headers,
          body: request.body.try { |bytes| IO::Memory.new(bytes) })
        result = {} of String => String
        response.headers.each { |name, values| result[name.downcase] = values.join(", ") }
        Response.new(response.status_code, result, response.body.to_slice)
      rescue ex : IO::Error | Socket::Error | OpenSSL::Error
        raise ConnectorError.new("#{uri.try(&.host)} injoignable : #{ex.message}", nil,
          "einvoicing.errors.transport.unreachable", {"host" => uri.try(&.host).to_s, "detail" => ex.message.to_s})
      ensure
        client.try(&.close)
      end
    end

    @@transport : Transport?

    # Transport en usage (réseau réel par défaut).
    def self.transport : Transport
      @@transport ||= NetTransport.new
    end

    # Remplace le transport (specs : plateforme simulée) ; `nil` revient au
    # réseau réel.
    def self.transport=(transport : Transport?) : Transport?
      @@transport = transport
    end

    def self.exec(method : String, url : String, headers = {} of String => String, body : Bytes? = nil) : Response
      transport.exec(Request.new(method, url, headers, body))
    end

    # Corps `multipart/form-data` : champs texte (avec leur type) et fichiers.
    # Rend le corps et l'en-tête `Content-Type`.
    def self.multipart(fields : Array({String, String, String?}), files : Array({String, String, String, Bytes})) : {Bytes, String}
      io = IO::Memory.new
      boundary = "partiduo-#{Random::Secure.hex(12)}"
      HTTP::FormData.build(io, boundary) do |builder|
        fields.each do |(name, value, type)|
          headers = type ? HTTP::Headers{"Content-Type" => type} : HTTP::Headers.new
          builder.field(name, value, headers)
        end
        files.each do |(name, filename, type, bytes)|
          builder.file(name, IO::Memory.new(bytes), HTTP::FormData::FileMetadata.new(filename: filename),
            HTTP::Headers{"Content-Type" => type})
        end
      end
      {io.to_slice, "multipart/form-data; boundary=#{boundary}"}
    end

    # Corps `application/x-www-form-urlencoded`.
    def self.form(fields : Hash(String, String)) : Bytes
      URI::Params.encode(fields).to_slice
    end
  end
end
