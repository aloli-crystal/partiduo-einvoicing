# SPDX-License-Identifier: AGPL-3.0-or-later

module Einvoicing
  # E-reporting (ADR-004 D8) : les ventes B2C sont transmises comme des
  # factures (note `BAR` = `B2C`) puis « Encaissée » au paiement ; les
  # ventes internationales sont déclarées par lots mensuels
  # (`send_ereporting`). Interne.
  module EReporting
    def self.queue!(row : Transmission, view : Partiduo::Api::Invoicing::DocumentView) : Report
      issued = row.issue_date || Partiduo::Api::Core.today
      sign = row.kind == "credit_note" ? -1 : 1
      entry = {
        "invoice_number"      => row.number.to_s,
        "date"                => issued.to_s("%Y-%m-%d"),
        "type_code"           => row.type_code.to_s,
        "currency_code"       => row.currency_code.to_s,
        "net"                 => Formats.plain(row.total_net! * sign),
        "vat"                 => Formats.plain(row.total_vat! * sign),
        "gross"               => Formats.plain(row.total_gross! * sign),
        "counterpart_country" => row.customer_country.to_s,
        "counterpart_name"    => row.customer_name.to_s,
        "counterpart_vat"     => view.customer.vat_number,
        "category"            => view.operation_category,
      }
      Report.create!(kind: "international_sales", transmission_id: row.id, period: Time.utc(issued.year, issued.month, 1),
        entry: JSON.parse(entry.to_json), state: "to_send")
    end

    # Envoie les lots à déclarer (nature × mois) ; rend le nombre de lignes
    # déclarées et les erreurs.
    def self.send_pending(connector : Connector) : {Int32, Array(String)}
      sent = 0
      errors = [] of String
      rows = Report.filter(state__in: %w[to_send failed]).order(:period, :id).to_a
      settings = Partiduo::Api::Core.settings(Partiduo::Api::Actor.system)
      declarant = Connector::Party.new(name: settings.company_name, siren: settings.siren.gsub(/\D/, ""),
        vat_number: settings.vat_number, country_code: settings.country_code)
      rows.group_by { |row| {row.kind.to_s, row.period!} }.each do |(kind, period), group|
        batch_ref = "ER-#{period.to_s("%Y%m")}-#{Random::Secure.hex(6)}"
        entries = group.map { |row| entry_of(row) }
        batch = Connector::EReportingBatch.new(kind: kind, period_start: period,
          period_end: period.shift(months: 1) - 1.day, declarant: declarant, entries: entries, tracking_id: batch_ref)
        state, error = begin
          connector.send_ereporting(batch)
          {"sent", ""}
        rescue ex : Unsupported
          {"not_applicable", ex.text}
        rescue ex : ConnectorError
          errors << ex.text
          {"failed", ex.text}
        end
        ids = group.map(&.id!.to_i64)
        Report.filter(id__in: ids).update(state: state, error: error, batch_ref: batch_ref,
          sent_at: state == "sent" ? Time.utc : nil, updated_at: Time.utc)
        sent += group.size if state == "sent"
      end
      {sent, errors}
    end

    private def self.entry_of(row : Report) : Connector::EReportingEntry
      data = row.entry.try(&.as_h?) || {} of String => JSON::Any
      text = ->(key : String) { data[key]?.try(&.as_s?) || "" }
      amount = ->(key : String) { Formats.decimal(text.call(key)) || BigDecimal.new(0) }
      Connector::EReportingEntry.new(
        invoice_number: text.call("invoice_number"), date: Formats.date(text.call("date")) || row.period!,
        type_code: text.call("type_code"), currency_code: text.call("currency_code"), net: amount.call("net"),
        vat: amount.call("vat"), gross: amount.call("gross"), counterpart_country: text.call("counterpart_country"),
        counterpart_name: text.call("counterpart_name"), counterpart_vat: text.call("counterpart_vat"),
        category: text.call("category").presence || "services",
      )
    end
  end
end
