# SPDX-License-Identifier: AGPL-3.0-or-later

module Einvoicing
  module Connectors
    # Adaptateur NOALYSS-PEPPOL (ADR-004 D2) : reprise de `peppol-connect`
    # (`class/peppol_synchro.class.php`), point d'accès PEPPOL de l'éditeur
    # de NOALYSS, réservé aux dossiers belges (régime `be`).
    #
    # Différences avec l'amont :
    #
    # * TLS *vérifié* (l'amont passait `CURLOPT_SSL_VERIFYPEER => false`) et
    #   adresse HTTPS exigée ;
    # * jeton permanent (`peppol_token`) et jeton de session (`authorization`,
    #   valable 20 minutes) chiffrés en base, pas en session PHP ;
    # * la facture transmise est l'UBL PEPPOL BIS Billing 3.0 produit par
    #   l'extension depuis la facture émise du module Facturation.
    #
    # Le point d'accès ne connaît ni statut de cycle de vie, ni e-reporting,
    # ni annuaire : `fetch_statuses` rend une page vide, les autres lèvent
    # `Unsupported`. La réception rend toutes les factures en attente puis
    # les confirme (`/1/acknowledge`) ; le curseur retient la dernière lue.
    class NoalyssPeppol < Connector
      CODE = "NOALYSS_PEPPOL"
      # Durée de validité retenue pour le jeton de session (20 minutes chez
      # l'éditeur), avec une marge.
      SESSION = 15.minutes

      FIELDS = [
        Connections::Field.new("url", kind: "url"),
        Connections::Field.new("participant_id"),
        Connections::Field.new("user_id"),
        Connections::Field.new("token", secret: true),
        Connections::Field.new("environment", kind: "choice", choices: %w[sandbox production]),
      ]

      def self.adapter : Connections::Adapter
        Connections::Adapter.new(CODE, "einvoicing.adapters.noalyss_peppol", %w[be], FIELDS,
          ->(settings : Connections::Settings) { new(settings).as(Connector) })
      end

      getter settings : Connections::Settings

      def initialize(@settings)
      end

      def mode : String
        settings["environment"] == "production" ? "production" : "sandbox"
      end

      def preferred_syntax : String
        "UBL"
      end

      def check : Nil
        settings.clear_tokens
        session
      end

      def submit(invoice : OutgoingInvoice) : Submission
        param = {"uuid" => invoice.tracking_id, "email" => "",
                 "peppol_to" => "#{invoice.buyer.scheme}:#{invoice.buyer.electronic_address}"}
        body, type = Http.multipart([{"param", param.to_json, nil}] of {String, String, String?},
          [{"file", invoice.filename, invoice.content_type, invoice.content}])
        response = call("POST", url("/1/documents/outgoing"), body, type)
        ensure_success!(response)
        json = response.json
        answer = json.as_a?.try(&.first?) || json
        status = answer["status"]?.try(&.as_s?) || "queued"
        failed = {"validation_failed", "failed"}.includes?(status)
        Submission.new(platform_ref: answer["id"]?.try(&.as_s?) || answer["uuid"]?.try(&.as_s?) || invoice.tracking_id,
          status: failed ? "error" : "pending", reason_code: failed ? status : "",
          reason: answer["message"]?.try(&.as_s?) || "")
      end

      def fetch_incoming(after : Cursor?) : Page(IncomingInvoice)
        response = call("GET", url("/1/documents/incoming?format=full"))
        ensure_success!(response)
        documents = response.text.strip.empty? ? [] of JSON::Any : (response.json.as_a? || [] of JSON::Any)
        items = documents.compact_map do |document|
          uuid = document["uuid"]?.try(&.as_s?)
          payload = document["xml_payload"]?.try(&.as_s?)
          next unless uuid && payload
          IncomingInvoice.new(platform_ref: uuid, filename: "#{uuid}.xml", content: payload.to_slice, syntax: "UBL",
            sender: document["senderPeppolId"]?.try(&.as_s?) || "",
            received_at: received_at(document["date_received"]?.try(&.as_s?)))
        end
        cursor = items.last?.try { |item| Cursor.new(item.platform_ref) } || after
        Page(IncomingInvoice).new(items, cursor, false)
      end

      def acknowledge(invoices : Array(IncomingInvoice)) : Nil
        return if invoices.empty?
        response = call("POST", url("/1/acknowledge"), Http.form({"uuid" => invoices.map(&.platform_ref).to_json}),
          "application/x-www-form-urlencoded")
        ensure_success!(response)
      end

      def fetch_statuses(after : Cursor?) : Page(LifecycleEvent)
        Page(LifecycleEvent).new([] of LifecycleEvent, after, false)
      end

      def send_status(event : LifecycleEvent) : Nil
        raise Unsupported.new("le point d'accès NOALYSS-PEPPOL n'échange pas de statuts", key: "einvoicing.errors.transport.no_statuses")
      end

      def send_ereporting(batch : EReportingBatch) : Nil
        raise Unsupported.new("pas d'e-reporting par le point d'accès NOALYSS-PEPPOL", key: "einvoicing.errors.transport.no_ereporting")
      end

      private def url(path : String) : String
        "#{settings["url"].rstrip('/')}#{path}"
      end

      # `Noalyss-Authz: Bearer <session>  <utilisateur>` (deux espaces, comme
      # l'amont). Un 401 rouvre la session et réessaie une fois
      # (`Peppol_Synchro::reconnect`).
      private def call(method : String, target : String, body : Bytes? = nil, type : String? = nil,
                       retry : Bool = true) : Http::Response
        headers = {"Noalyss-Authz" => "Bearer #{session}  #{settings["user_id"]}", "Accept" => "application/json"}
        headers["Content-Type"] = type if type
        response = Http.exec(method, target, headers, body)
        if response.status == 401 && retry
          settings.clear_tokens
          return call(method, target, body, type, retry: false)
        end
        response
      end

      # Jeton de session : ouvert par `/cnx2` avec le jeton permanent.
      private def session : String
        if current = settings.access_token
          return current
        end
        response = Http.exec("POST", url("/cnx2"), {"Noalyss-Authz" => settings["token"],
                                                    "Content-Type"  => "application/x-www-form-urlencoded"},
          Http.form({"participantId" => settings["participant_id"], "userId" => settings["user_id"]}))
        raise ConnectorError.new("connexion refusée (#{response.status})", response.status, "einvoicing.errors.transport.auth_refused", {"status" => response.status.to_s}) unless response.success?
        json = response.json
        raise ConnectorError.new("données de connexion invalides", nil, "einvoicing.errors.transport.missing_field", {"field" => "transfer"}) unless json["transfer"]?
        authorization = json["authorization"]?.try(&.as_s?) || json["autorization"]?.try(&.as_s?) ||
                        raise ConnectorError.new("réponse de connexion sans jeton", nil, "einvoicing.errors.transport.missing_field", {"field" => "authorization"})
        settings.store_tokens(authorization, Time.utc + SESSION)
        authorization
      end

      private def ensure_success!(response : Http::Response) : Nil
        return if response.success?
        raise ConnectorError.new("point d'accès : #{response.status} #{response.text[0, 200]}".strip, response.status, "einvoicing.errors.transport.platform", {"status" => response.status.to_s, "detail" => response.text[0, 200]})
      end

      # `date_received` au format de l'amont (`DD.MM.YYYY HH24:MI:SS`) ou ISO.
      private def received_at(text : String?) : Time
        value = text.to_s.strip
        return Time.parse_utc(value, "%d.%m.%Y %H:%M:%S") if value.matches?(/\A\d{2}\.\d{2}\.\d{4} \d{2}:\d{2}:\d{2}\z/)
        Time.parse_rfc3339(value)
      rescue Time::Format::Error
        Time.utc
      end
    end
  end

  Connections.register(Connectors::Afnor.adapter)
  Connections.register(Connectors::NoalyssPeppol.adapter)
end
