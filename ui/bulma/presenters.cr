# SPDX-License-Identifier: AGPL-3.0-or-later

module Einvoicing
  module Ui
    # Ligne présentée à un gabarit : textes déjà mis en forme, par nom.
    # Une classe plutôt qu'un `Hash` : le moteur de gabarits de Marten ne
    # retrouve pas les clés d'un grand `Hash` (`Marten::Template::Value` sans
    # `#hash`, BLOCAGES B-EINV-001).
    class Row
      include Marten::Template::Object

      getter values : Hash(String, String?)

      def initialize(@values : Hash(String, String?))
      end

      def [](key : String) : String?
        values[key]?
      end

      def resolve_template_attribute(key : String)
        values[key]?
      end
    end

    def self.row(values : Hash(String, String?)) : Row
      Row.new(values)
    end

    def self.row(values : Hash(String, String)) : Row
      Row.new(values.transform_values(&.as(String?)))
    end

    # Adaptateur présenté à l'écran de raccordement.
    class AdapterCard
      include Marten::Template::Object::Auto

      getter code : String
      getter label : String
      getter active : Bool
      getter fields : Array(Row)
      getter choices : Array(Row)

      def initialize(@code, @label, @active, @fields, @choices)
      end
    end

    # Présentation des vues du contrat pour les gabarits : textes déjà mis en
    # forme dans la langue de l'utilisateur, adresses des actions.
    module Present
      alias Api = Einvoicing::Api

      def self.transmission(view : Api::TransmissionView, fmt : PartiduoUi::Format) : Row
        Ui.row({
          "id"                => view.id.to_s,
          "invoice_id"        => view.invoice_id.to_s,
          "number"            => view.number,
          "kind"              => I18n.t("invoicing.kinds.#{view.kind}"),
          "customer"          => view.customer_name,
          "country"           => view.customer_country,
          "date"              => fmt.date(view.issue_date),
          "total"             => "#{fmt.amount(view.total_gross)} #{view.currency_code}",
          "route"             => view.route,
          "route_label"       => I18n.t(view.route_key),
          "status"            => view.status,
          "status_label"      => I18n.t(view.status_key),
          "tone"              => tone(view.status),
          "platform_required" => view.platform_required ? "1" : nil,
          "transmittable"     => view.transmittable? ? "1" : nil,
          "platform_ref"      => view.platform_ref,
          "tracking_id"       => view.tracking_id,
          "adapter"           => view.adapter.presence,
          "syntax"            => view.syntax.presence,
          "submitted_at"      => view.submitted_at.try { |time| fmt.datetime(time) },
          "error"             => view.error.presence,
          "show_url"          => Ui.url("outgoing_show", view.id),
          "transmit_url"      => Ui.url("transmit", view.id),
          "invoice_url"       => Ui.route("invoicing:document", id: view.invoice_id),
        } of String => String?)
      end

      def self.reception(view : Api::ReceptionView, fmt : PartiduoUi::Format) : Row
        Ui.row({
          "id"           => view.id.to_s,
          "number"       => view.number.presence || "—",
          "supplier"     => view.supplier_name.presence || "—",
          "siren"        => view.supplier_siren.presence,
          "vat"          => view.supplier_vat.presence,
          "date"         => fmt.date(view.issue_date),
          "due"          => fmt.date(view.due_date),
          "received"     => fmt.datetime(view.received_at),
          "net"          => view.total_net.try { |value| fmt.amount(value) },
          "vat_total"    => view.total_vat.try { |value| fmt.amount(value) },
          "total"        => view.total_gross.try { |value| "#{fmt.amount(value)} #{view.currency_code}".strip },
          "syntax"       => view.syntax.presence || "?",
          "profile"      => view.profile.presence,
          "credit"       => view.credit_note? ? "1" : nil,
          "status"       => view.status,
          "status_label" => I18n.t(view.status_key),
          "tone"         => tone(view.status),
          "undecided"    => view.undecided? ? "1" : nil,
          "card"         => view.supplier_card_id ? "1" : nil,
          "show_url"     => Ui.url("incoming_show", view.id),
          "accept_url"   => Ui.url("accept", view.id),
          "refuse_url"   => Ui.url("refuse", view.id),
          "post_url"     => Ui.url("post", view.id),
          "original_url" => Ui.url("incoming_file", view.id, "original"),
          "xml_url"      => Ui.url("incoming_file", view.id, "xml"),
          "entry_url"    => view.entry_id.try { |id| Ui.route("accounting:entry", id: id) },
          "receipt_url"  => view.receipt_id.try { |id| Ui.route("document:show", id: id) },
          "platform_ref" => view.platform_ref,
          "read_errors"  => view.read_errors.empty? ? nil : view.read_errors.join(" ; "),
        } of String => String?)
      end

      def self.event(view : Api::EventView, fmt : PartiduoUi::Format) : Row
        Ui.row({
          "code"   => view.code,
          "label"  => I18n.t(view.label_key),
          "date"   => fmt.datetime(view.occurred_at),
          "issuer" => I18n.t(view.issuer_key),
          "reason" => [view.reason_code.presence.try { |code| Api::REFUSAL_REASONS.includes?(code) ? I18n.t("einvoicing.refusal_reasons.#{code}") : code },
                       view.reason.presence].compact.join(" : ").presence,
          "amount" => view.amount.try { |value| fmt.amount(value) },
          "state"  => I18n.t(view.state_key),
          "error"  => view.error.presence,
        } of String => String?)
      end

      # Couleur Bulma d'un statut.
      def self.tone(status : String) : String
        case status
        when "deposited", "approved", "paid", "posted", "accepted" then "is-success"
        when "rejected", "refused"                                 then "is-danger"
        when "pending", "received"                                 then "is-warning"
        else                                                            "is-info"
        end
      end
    end

    # Adresse d'une route de l'extension (`einv:<nom>`).
    def self.url(name : String, id : Int64? = nil, variant : String? = nil) : String
      if variant && id
        if name == "outgoing_file"
          Marten.routes.reverse("einv:#{name}", id: id, format: variant)
        else
          Marten.routes.reverse("einv:#{name}", id: id, variant: variant)
        end
      elsif id
        Marten.routes.reverse("einv:#{name}", id: id)
      else
        Marten.routes.reverse("einv:#{name}")
      end
    end

    # Adresse d'un écran de l'interface ou d'une autre extension, `nil` s'il
    # n'existe pas.
    def self.route(name : String, **params) : String?
      Marten.routes.reverse(name, **params)
    rescue Marten::Routing::Errors::NoReverseMatch
      nil
    end
  end
end
