# SPDX-License-Identifier: AGPL-3.0-or-later

require "http/formdata"
require "mime/multipart"

module Einvoicing
  module SpecSupport
    # Plateforme agréée simulée (ADR-004 D6) : double du transport HTTP qui
    # reproduit les réponses documentées de l'API XP Z12-013 1.3.0 (Flux et
    # Annuaire, OAuth 2 client credentials, `https://pa.test`) et de l'API
    # Peppol Belgique (`https://peppol.test`). Les specs y déposent des
    # factures reçues et des statuts, et lisent ce que l'extension y a
    # envoyé.
    class SimulatedPlatform < Einvoicing::Http::Transport
      alias Request = Einvoicing::Http::Request
      alias Response = Einvoicing::Http::Response

      CLIENT_ID     = "partiduo-client"
      CLIENT_SECRET = "s3cr3t-client"
      PEPPOL_TOKEN  = "peppolToken42"
      PEPPOL_HEADER = "Peppol-Authz"

      class Flow
        property id : String
        property name : String
        property syntax : String
        property profile : String
        property type : String
        property direction : String
        property rule : String
        property tracking_id : String
        property content : Bytes
        property ack : String
        property reason : String = ""
        property submitted_at : Time
        property updated_at : Time

        def initialize(@id, @name, @syntax, @profile, @type, @direction, @rule, @tracking_id, @content, @ack,
                       @submitted_at, @updated_at)
        end

        def to_json_any : Hash(String, JSON::Any)
          ack_json = {"status" => ack} of String => String | Array(Hash(String, String))
          unless reason.empty?
            ack_json["details"] = [{"item" => "invoice", "level" => "Error", "reasonCode" => "REJ_SEMAN",
                                    "reasonMessage" => reason}]
          end
          JSON.parse({
            "flowId" => id, "name" => name, "flowSyntax" => syntax, "flowProfile" => profile, "flowType" => type,
            "flowDirection" => direction, "processingRule" => rule, "processingRuleSource" => "Input",
            "trackingId" => tracking_id, "submittedAt" => submitted_at.to_rfc3339(fraction_digits: 3),
            "updatedAt" => updated_at.to_rfc3339(fraction_digits: 3), "acknowledgement" => ack_json,
          }.to_json).as_h
        end
      end

      getter flows = [] of Flow
      getter requests = [] of Request
      getter tokens = [] of String
      getter revoked = Set(String).new
      # Réponse d'erreur forcée pour la prochaine requête d'API (hors jeton).
      property fail_next : Int32? = nil
      # Nombre de flux par page de recherche (petit, pour la pagination).
      property page_size : Int32 = 2
      # Recherche sans curseur : ni `nextCursor` ni décalage, `total` rendu
      # (plateforme qui s'écarte de la norme, adaptateur hérité).
      property? cursorless : Bool = false
      # Ordre des flux d'une recherche sans curseur : "asc" (par `updatedAt`
      # croissant), "desc" (les plus récents d'abord) ou "shuffled" (mêlés,
      # graine fixe) — la norme ne garantit pas le tri (D-ESL-002).
      property result_order : String = "asc"
      # Annuaire.
      property directory = [] of Hash(String, JSON::Any)
      # Point d'accès Peppol Belgique.
      getter peppol_sent = [] of {Hash(String, String), String, Bytes}
      getter peppol_inbox = [] of {String, String, String}
      getter peppol_acknowledged = [] of String
      getter peppol_sessions = 0

      @clock = Time.utc(2026, 9, 1, 8, 0, 0)
      @sequence = 0

      # Horloge de la plateforme : chaque changement avance d'une seconde.
      def tick : Time
        @clock += 1.second
      end

      def exec(request : Request) : Response
        @requests << request
        uri = URI.parse(request.url)
        return peppol(request, uri) if uri.host == "peppol.test"
        raise "hôte inattendu #{uri.host}" unless uri.host == "pa.test"
        return token(request) if uri.path == "/oauth2/token"
        bearer = request.headers["Authorization"]?.to_s.lchop("Bearer ")
        return json(401, {"errorCode" => "UNAUTHORIZED"}) if !tokens.includes?(bearer) || revoked.includes?(bearer)
        if status = fail_next
          @fail_next = nil
          return json(status, {"errorCode" => "SERVER_ERROR", "errorMessage" => "indisponible"})
        end
        case {request.method, uri.path}
        when {"GET", "/afnor-flow/v1/healthcheck"}
          json(200, {} of String => String)
        when {"POST", "/afnor-flow/v1/flows"}
          submit(request)
        when {"POST", "/afnor-flow/v1/flows/search"}
          search(request)
        when {"POST", "/afnor-directory/v1/directory-line/search"}
          lookup(request)
        else
          if request.method == "GET" && (id = uri.path.lchop?("/afnor-flow/v1/flows/"))
            flow = flows.find { |item| item.id == id } || return json(404, {"errorCode" => "NOT_FOUND"})
            Response.new(200, {"content-type" => "application/octet-stream"}, flow.content)
          else
            json(404, {"errorCode" => "NOT_FOUND"})
          end
        end
      end

      # --- Côté plateforme : ce que les specs déposent ------------------------------

      # Facture d'un fournisseur livrée au dossier.
      def deliver(content : Bytes, name : String, syntax : String) : Flow
        add(Flow.new(next_id, name, syntax, "CIUS", "SupplierInvoice", "In", "B2B", "", content, "Ok", tick, @clock))
      end

      # Contrôle d'un flux déposé par le dossier : `Ok` (Déposée) ou `Error`
      # (Rejetée, avec motif).
      def acknowledge(flow : Flow, status : String, reason : String = "") : Nil
        flow.ack = status
        flow.reason = reason
        flow.updated_at = tick
      end

      # Statut émis par l'acheteur sur une facture du dossier (CDAR).
      def buyer_status(number : String, code : String, reason_code : String = "", reason : String = "") : Flow
        event = Einvoicing::Connector::LifecycleEvent.new(code: code, occurred_at: tick, invoice_number: number,
          issuer: "buyer", reason_code: reason_code, reason: reason)
        xml = Einvoicing::Formats::Cdar.build(event, "LC-#{@sequence}")
        add(Flow.new(next_id, "lc.xml", "CDAR", "Undefined", "CustomerInvoiceLC", "In", "B2B", "", xml.to_slice, "Ok",
          @clock, @clock))
      end

      def sent(type : String? = nil, syntax : String? = nil) : Array(Flow)
        flows.select { |flow| flow.direction == "Out" && (type.nil? || flow.type == type) && (syntax.nil? || flow.syntax == syntax) }
      end

      # --- API XP Z12-013 ------------------------------------------------------------

      private def token(request : Request) : Response
        form = URI::Params.parse(String.new(request.body || Bytes.empty))
        unless form["client_id"]? == CLIENT_ID && form["client_secret"]? == CLIENT_SECRET
          return json(401, {"error" => "invalid_client"})
        end
        value = "tok-#{tokens.size + 1}"
        tokens << value
        json(200, {"access_token" => value, "token_type" => "Bearer", "expires_in" => 1800})
      end

      private def submit(request : Request) : Response
        info = {} of String => JSON::Any
        name = ""
        content = Bytes.empty
        boundary = MIME::Multipart.parse_boundary(request.headers["Content-Type"]) || raise "multipart sans boundary"
        HTTP::FormData.parse(IO::Memory.new(request.body || Bytes.empty), boundary) do |part|
          case part.name
          when "flowInfo" then info = JSON.parse(part.body.gets_to_end).as_h
          when "file"
            name = part.filename || "file"
            content = part.body.getb_to_end
          end
        end
        syntax = info["flowSyntax"]?.try(&.as_s) || return json(400, {"errorCode" => "MISSING_REQUIRED_FIELD"})
        type = case syntax
               when "CDAR" then "CustomerInvoiceLC"
               when "FRR"  then "UnitaryCustomerTransactionReport"
               else             "CustomerInvoice"
               end
        now = tick
        flow = add(Flow.new(next_id, info["name"]?.try(&.as_s) || name, syntax, info["flowProfile"]?.try(&.as_s) || "Undefined",
          type, "Out", info["processingRule"]?.try(&.as_s) || "B2B", info["trackingId"]?.try(&.as_s) || "", content, "Pending",
          now, now))
        Response.new(202, {"content-type" => "application/json"}, JSON.build do |builder|
          builder.object do
            builder.field "flowId", flow.id
            builder.field "submittedAt", now.to_rfc3339
            builder.field "name", flow.name
            builder.field "flowSyntax", syntax
          end
        end.to_slice)
      end

      private def search(request : Request) : Response
        body = JSON.parse(String.new(request.body || Bytes.empty))
        where = body["where"]
        types = where["flowType"]?.try(&.as_a.map(&.as_s))
        directions = where["flowDirection"]?.try(&.as_a.map(&.as_s))
        after = where["updatedAfter"]?.try { |value| Time.parse_rfc3339(value.as_s) }
        matching = flows.select do |flow|
          (types.nil? || types.includes?(flow.type)) && (directions.nil? || directions.includes?(flow.direction)) &&
            (after.nil? || flow.updated_at > after)
        end.sort_by! { |flow| {flow.updated_at, flow.id} }
        if cursorless?
          case result_order
          when "desc"     then matching.reverse!
          when "shuffled" then matching.shuffle!(Random.new(42))
          end
        end
        offset = cursorless? ? 0 : (body["cursor"]?.try(&.as_s.lchop("off:").to_i) || 0)
        limit = Math.min(body["limit"]?.try(&.as_i) || 25, page_size)
        page = matching[offset, limit]? || [] of Flow
        result = {"results" => page.map(&.to_json_any), "limit" => limit} of String => Array(Hash(String, JSON::Any)) | Int32 | String
        if cursorless?
          result["total"] = matching.size
        elsif offset + limit < matching.size
          result["nextCursor"] = "off:#{offset + limit}"
        end
        json(200, result)
      end

      private def lookup(request : Request) : Response
        body = JSON.parse(String.new(request.body || Bytes.empty))
        filters = body["filters"].as_h
        results = directory.select do |line|
          filters.all? do |key, filter|
            value = filter["value"].as_s
            field = line[key]?.try(&.as_s) || ""
            filter["op"].as_s == "contains" ? field.includes?(value) : field == value
          end
        end
        json(200, {"results" => results, "totalNumberOfResults" => results.size})
      end

      # --- API Peppol Belgique -------------------------------------------------------

      private def peppol(request : Request, uri : URI) : Response
        if uri.path == "/cnx2"
          return json(401, {"error" => "token"}) unless request.headers[PEPPOL_HEADER]? == PEPPOL_TOKEN
          @peppol_sessions += 1
          return json(200, {"transfer" => "ok", "peppol_id" => "0208:0417497106", "authorization" => "sess-#{@peppol_sessions}"})
        end
        expected = "Bearer sess-#{@peppol_sessions}  PDUO"
        return json(401, {"error" => "session"}) unless request.headers[PEPPOL_HEADER]? == expected
        case {request.method, uri.path}
        when {"POST", "/1/documents/outgoing"}
          boundary = MIME::Multipart.parse_boundary(request.headers["Content-Type"]) || raise "multipart sans boundary"
          param = {} of String => String
          name = ""
          content = Bytes.empty
          HTTP::FormData.parse(IO::Memory.new(request.body || Bytes.empty), boundary) do |part|
            case part.name
            when "param" then param = Hash(String, String).from_json(part.body.gets_to_end)
            when "file"
              name = part.filename || ""
              content = part.body.getb_to_end
            end
          end
          @peppol_sent << {param, name, content}
          json(200, {"id" => param["uuid"], "status" => "queued"})
        when {"GET", "/1/documents/incoming"}
          pending = peppol_inbox.reject { |(uuid, _, _)| peppol_acknowledged.includes?(uuid) }
          documents = pending.map do |(uuid, xml, sender)|
            {"uuid" => uuid, "xml_payload" => xml, "senderPeppolId" => sender, "date_received" => "25.09.2026 10:15:00"}
          end
          json(200, documents)
        when {"POST", "/1/acknowledge"}
          form = URI::Params.parse(String.new(request.body || Bytes.empty))
          @peppol_acknowledged.concat(Array(String).from_json(form["uuid"]))
          json(200, {"status" => "ok"})
        else
          json(404, {"error" => "not found"})
        end
      end

      private def add(flow : Flow) : Flow
        flows << flow
        flow
      end

      private def next_id : String
        "flow-#{@sequence += 1}"
      end

      private def json(status : Int32, body) : Response
        Response.new(status, {"content-type" => "application/json"}, body.to_json.to_slice)
      end
    end
  end
end
