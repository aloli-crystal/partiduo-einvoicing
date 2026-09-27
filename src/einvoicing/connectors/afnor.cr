# SPDX-License-Identifier: AGPL-3.0-or-later

require "digest/sha256"

module Einvoicing
  module Connectors
    # Adaptateur XP Z12-013 (ADR-004 D2) : l'API normalisée entre logiciel et
    # plateforme agréée, version 1.3.0 — *API Flux* (dépôt et recherche des
    # flux : factures, messages de cycle de vie CDAR, e-reporting) et *API
    # Annuaire* (lignes d'adressage). Couvre toute plateforme qui
    # l'implémente, SuperPDP compris (`https://api.superpdp.tech/afnor-flow`,
    # `…/afnor-directory`).
    #
    # Authentification OAuth 2 *client credentials* : le jeton d'accès est
    # conservé chiffré et renouvelé à l'expiration ; un refus 401 le jette et
    # réessaie une fois. Un jeton de rafraîchissement rendu par la
    # plateforme est utilisé puis remplacé (rotation).
    #
    # Synchronisation : la recherche de flux pagine par curseur opaque
    # (`nextCursor`), absent à la dernière page. Le curseur conservé est
    # alors l'horodatage du dernier flux lu ; la reprise relit avec un
    # recouvrement de dix minutes et l'enregistrement idempotent écarte les
    # flux déjà vus (DECISIONS D-EINV-005).
    class Afnor < Connector
      CODE    = "AFNOR"
      OVERLAP = 10.minutes
      LIMIT   = 50

      # Profils XP Z12-013 (`FlowProfile`).
      PROFILES = {"EN16931" => "CIUS", "EXTENDED-CTC-FR" => "Extended-CTC-FR", "BASIC-WL" => "Basic"}

      FIELDS = [
        Connections::Field.new("flow_url", kind: "url"),
        Connections::Field.new("directory_url", kind: "url", required: false),
        Connections::Field.new("token_url", kind: "url"),
        Connections::Field.new("client_id"),
        Connections::Field.new("client_secret", secret: true),
        Connections::Field.new("organization_id", required: false),
        Connections::Field.new("environment", kind: "choice", choices: %w[sandbox production]),
      ]

      def self.adapter : Connections::Adapter
        Connections::Adapter.new(CODE, "einvoicing.adapters.afnor", %w[fr be], FIELDS,
          ->(settings : Connections::Settings) { new(settings).as(Connector) })
      end

      getter settings : Connections::Settings

      def initialize(@settings)
      end

      def mode : String
        settings["environment"] == "production" ? "production" : "sandbox"
      end

      def check : Nil
        response = call("GET", flow_url("/v1/healthcheck"))
        raise ConnectorError.new("plateforme indisponible (#{response.status})", response.status) unless response.success?
      end

      def submit(invoice : OutgoingInvoice) : Submission
        info = {
          "flowSyntax"     => invoice.syntax,
          "flowProfile"    => PROFILES[invoice.profile]? || "CIUS",
          "name"           => invoice.filename,
          "trackingId"     => invoice.tracking_id,
          "processingRule" => invoice.processing_rule,
          "sha256"         => invoice.sha256,
        }
        body = post_flow(info, invoice.filename, invoice.content_type, invoice.content)
        submission(body)
      end

      def fetch_incoming(after : Cursor?) : Page(IncomingInvoice)
        results, cursor, more = search({"flowType" => ["SupplierInvoice"], "flowDirection" => ["In"]}, after)
        items = results.compact_map do |flow|
          next if flow["acknowledgement"]?.try(&.["status"]?.try(&.as_s?)) == "Error"
          id = flow["flowId"].as_s
          IncomingInvoice.new(platform_ref: id, filename: flow["name"]?.try(&.as_s?) || "#{id}.xml",
            content: download(id), syntax: flow["flowSyntax"]?.try(&.as_s?),
            received_at: time_of(flow["submittedAt"]?) || Time.utc)
        end
        Page(IncomingInvoice).new(items, cursor, more)
      end

      def fetch_statuses(after : Cursor?) : Page(LifecycleEvent)
        filters = {"flowType" => ["CustomerInvoice", "CustomerInvoiceLC", "SupplierInvoiceLC"]}
        results, cursor, more = search(filters, after)
        events = [] of LifecycleEvent
        results.each do |flow|
          id = flow["flowId"].as_s
          type = flow["flowType"]?.try(&.as_s?) || ""
          direction = flow["flowDirection"]?.try(&.as_s?) || ""
          updated = time_of(flow["updatedAt"]?) || Time.utc
          if type == "CustomerInvoice" && direction == "Out"
            ack = flow["acknowledgement"]?
            status = ack.try(&.["status"]?.try(&.as_s?)) || "Pending"
            next if status == "Pending"
            detail = ack.try(&.["details"]?.try(&.as_a?.try(&.first?)))
            events << LifecycleEvent.new(code: status == "Ok" ? "200" : "213", occurred_at: updated,
              invoice_ref: id, issuer: "platform", platform_ref: "#{id}:#{status}",
              reason_code: detail.try(&.["reasonCode"]?.try(&.as_s?)) || "",
              reason: detail.try(&.["reasonMessage"]?.try(&.as_s?)) || "")
          elsif type.ends_with?("InvoiceLC") && direction == "In"
            Formats::Cdar.parse(download(id)).each_with_index do |status, index|
              events << LifecycleEvent.new(code: status.code, occurred_at: status.occurred_at,
                direction: type == "CustomerInvoiceLC" ? "outgoing" : "incoming",
                invoice_number: status.invoice_number, issuer: status.issuer, reason_code: status.reason_code,
                reason: status.reason, amount: status.amount, platform_ref: "#{id}:#{index}")
            end
          end
        end
        Page(LifecycleEvent).new(events, cursor, more)
      end

      def send_status(event : LifecycleEvent) : Nil
        id = "CDAR-#{Random::Secure.hex(8)}"
        xml = Formats::Cdar.build(event, id).to_slice
        info = {"flowSyntax" => "CDAR", "name" => "#{id}.xml", "trackingId" => id, "processingRule" => "B2B",
                "sha256" => Digest::SHA256.hexdigest(xml)}
        body = post_flow(info, "#{id}.xml", "application/xml", xml)
        result = submission(body)
        raise ConnectorError.new("statut rejeté : #{result.reason}") if result.status == "error"
      end

      def send_ereporting(batch : EReportingBatch) : Nil
        xml = Formats::EReport.build(batch).to_slice
        info = {"flowSyntax" => "FRR", "name" => "#{batch.tracking_id}.xml", "trackingId" => batch.tracking_id,
                "processingRule" => "B2BInt", "sha256" => Digest::SHA256.hexdigest(xml)}
        result = submission(post_flow(info, "#{batch.tracking_id}.xml", "application/xml", xml))
        raise ConnectorError.new("e-reporting rejeté : #{result.reason}") if result.status == "error"
      end

      def lookup(query : String) : Array(DirectoryEntry)
        base = settings["directory_url"]
        raise Unsupported.new("adresse de l'API Annuaire non renseignée") if base.empty?
        value = query.gsub(/\s/, "")
        filters = if value.matches?(/\A\d{9}\z/)
                    {"siren" => {"op" => "strict", "value" => value}}
                  elsif value.matches?(/\A\d{14}\z/)
                    {"siret" => {"op" => "strict", "value" => value}}
                  else
                    {"addressingIdentifier" => {"op" => "contains", "value" => query.strip}}
                  end
        body = {"filters" => filters, "limit" => 50}.to_json
        response = call("POST", "#{base.rstrip('/')}/v1/directory-line/search", body.to_slice, "application/json")
        ensure_success!(response)
        (response.json["results"]?.try(&.as_a?) || [] of JSON::Any).map do |line|
          text = ->(key : String) { line[key]?.try(&.as_s?) || "" }
          name = line["legalUnit"]?.try(&.["businessName"]?.try(&.as_s?)) ||
                 line["facility"]?.try(&.["name"]?.try(&.as_s?)) || ""
          address = text.call("addressingIdentifier")
          DirectoryEntry.new(address: address.presence || text.call("siren"), scheme: Formats::SCHEME_FR_ADDR, name: name,
            siren: text.call("siren"), siret: text.call("siret"), routing_id: text.call("routingIdentifier"),
            platform: text.call("platformType"), status: text.call("directoryLineStatus"))
        end
      end

      # --- Échanges --------------------------------------------------------------

      private def flow_url(path : String) : String
        "#{settings["flow_url"].rstrip('/')}#{path}"
      end

      private def post_flow(info : Hash(String, String), filename : String, content_type : String, content : Bytes) : JSON::Any
        body, type = Http.multipart([{"flowInfo", info.to_json, "application/json"}] of {String, String, String?},
          [{"file", filename, content_type, content}])
        response = call("POST", flow_url("/v1/flows"), body, type)
        ensure_success!(response)
        response.json
      end

      private def submission(body : JSON::Any) : Submission
        id = body["flowId"]?.try(&.as_s?) || raise ConnectorError.new("réponse de dépôt sans flowId")
        ack = body["acknowledgement"]?
        status = ack.try(&.["status"]?.try(&.as_s?)) || "Pending"
        detail = ack.try(&.["details"]?.try(&.as_a?.try(&.first?)))
        Submission.new(platform_ref: id, status: {"Ok" => "ok", "Error" => "error"}[status]? || "pending",
          reason_code: detail.try(&.["reasonCode"]?.try(&.as_s?)) || "",
          reason: detail.try(&.["reasonMessage"]?.try(&.as_s?)) || "")
      end

      # Recherche paginée de flux à partir du curseur conservé : rend les
      # flux, le curseur à conserver et s'il reste des pages.
      private def search(filters : Hash(String, Array(String)), after : Cursor?) : {Array(JSON::Any), Cursor?, Bool}
        state = after.try { |cursor| JSON.parse(cursor.value).as_h? } || {} of String => JSON::Any
        where = JSON.parse(filters.to_json).as_h
        request = {} of String => JSON::Any
        if next_cursor = state["c"]?.try(&.as_s?)
          request["cursor"] = JSON::Any.new(next_cursor)
        elsif last = state["t"]?.try(&.as_s?).try { |text| Time.parse_rfc3339(text) rescue nil }
          where["updatedAfter"] = JSON::Any.new((last - OVERLAP).to_rfc3339)
        end
        request["where"] = JSON::Any.new(where)
        request["limit"] = JSON::Any.new(LIMIT.to_i64)
        response = call("POST", flow_url("/v1/flows/search"), request.to_json.to_slice, "application/json")
        ensure_success!(response)
        body = response.json
        results = body["results"]?.try(&.as_a?) || [] of JSON::Any
        latest = results.compact_map { |flow| time_of(flow["updatedAt"]?) }.max? ||
                 state["t"]?.try(&.as_s?).try { |text| Time.parse_rfc3339(text) rescue nil }
        following = body["nextCursor"]?.try(&.as_s?).presence
        cursor = {} of String => String
        cursor["c"] = following if following
        cursor["t"] = latest.to_rfc3339 if latest
        {results, cursor.empty? ? after : Cursor.new(cursor.to_json), !following.nil?}
      end

      private def download(id : String) : Bytes
        response = call("GET", flow_url("/v1/flows/#{URI.encode_path_segment(id)}?docType=Original"))
        ensure_success!(response)
        response.body
      end

      private def time_of(value : JSON::Any?) : Time?
        value.try(&.as_s?).try { |text| Time.parse_rfc3339(text) rescue nil }
      end

      # Requête authentifiée ; un 401 renouvelle le jeton et réessaie une fois.
      private def call(method : String, url : String, body : Bytes? = nil, type : String? = nil,
                       retry : Bool = true) : Http::Response
        headers = {"Authorization" => "Bearer #{token}", "Accept" => "application/json",
                   "Request-Id" => UUID.random.to_s}
        headers["Content-Type"] = type if type
        organization = settings["organization_id"]
        headers["Organization-Id"] = organization unless organization.empty?
        response = Http.exec(method, url, headers, body)
        if response.status == 401 && retry
          settings.clear_tokens
          return call(method, url, body, type, retry: false)
        end
        response
      end

      private def ensure_success!(response : Http::Response) : Nil
        return if response.success?
        detail = begin
          json = response.json
          [json["errorCode"]?.try(&.as_s?), json["errorMessage"]?.try(&.as_s?)].compact.join(" : ")
        rescue ConnectorError
          response.text[0, 200]
        end
        raise ConnectorError.new("plateforme : #{response.status} #{detail}".strip, response.status)
      end

      # Jeton d'accès OAuth 2 : celui conservé s'il est valable, sinon
      # rafraîchi ou redemandé (client credentials).
      private def token : String
        if current = settings.access_token
          return current
        end
        fields = if refresh = settings.refresh_token
                   {"grant_type" => "refresh_token", "refresh_token" => refresh}
                 else
                   {"grant_type" => "client_credentials"}
                 end
        fields["client_id"] = settings["client_id"]
        fields["client_secret"] = settings["client_secret"]
        response = Http.exec("POST", settings["token_url"], {"Content-Type" => "application/x-www-form-urlencoded",
                                                             "Accept"       => "application/json"}, Http.form(fields))
        if !response.success? && fields["grant_type"] == "refresh_token"
          settings.store_tokens("", Time.utc, "")
          fields = {"grant_type" => "client_credentials", "client_id" => settings["client_id"],
                    "client_secret" => settings["client_secret"]}
          response = Http.exec("POST", settings["token_url"], {"Content-Type" => "application/x-www-form-urlencoded",
                                                               "Accept"       => "application/json"}, Http.form(fields))
        end
        raise ConnectorError.new("authentification refusée (#{response.status})", response.status) unless response.success?
        json = response.json
        access = json["access_token"]?.try(&.as_s?) || raise ConnectorError.new("réponse OAuth sans access_token")
        expires = json["expires_in"]?.try { |value| value.as_i64? || value.as_s?.try(&.to_i64?) }
        settings.store_tokens(access, Time.utc + (expires || 1800_i64).seconds, json["refresh_token"]?.try(&.as_s?))
        access
      end
    end
  end
end
