# SPDX-License-Identifier: AGPL-3.0-or-later

module Einvoicing
  # Transaction à déclarer en e-reporting (ADR-004 D8) : vente
  # internationale (`international_sales`). Les ventes B2C passent par la
  # transmission de la facture (note `BAR`) et « Encaissée » (212). Les
  # lignes à envoyer sont groupées par nature et par mois en un lot
  # (`EReportingBatch`).
  class Report < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :kind, :string, max_size: 32
    field :transmission_id, :big_int, blank: true, null: true, unique: true
    field :period, :date
    field :entry, :json
    # `to_send`, `sent`, `failed`, `not_applicable`.
    field :state, :string, max_size: 16, default: "to_send", index: true
    field :batch_ref, :string, max_size: 64, blank: true, default: ""
    field :sent_at, :date_time, blank: true, null: true
    field :error, :text, blank: true, default: ""

    with_timestamp_fields
  end
end
