# SPDX-License-Identifier: AGPL-3.0-or-later

module Einvoicing
  # Événement du cycle de vie d'une facture (ADR-004 D4 : code AFNOR, date,
  # motif, émetteur), sur une facture émise (`transmission_id`) ou reçue
  # (`reception_id`). Table `einvoicing_lifecycle_event` (préfixe de
  # l'application, ADR-003 D5, au lieu d'`invoice_lifecycle_events`).
  #
  # `state` : `received` (remonté de la plateforme), `to_send` (à émettre),
  # `sent`, `failed` (nouvelle tentative à la synchronisation),
  # `not_applicable` (plateforme sans cycle de vie, point d'accès PEPPOL).
  # `platform_ref` rend la lecture des statuts idempotente.
  class Event < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :transmission_id, :big_int, blank: true, null: true, index: true
    field :reception_id, :big_int, blank: true, null: true, index: true
    field :code, :string, max_size: 3
    field :occurred_at, :date_time
    field :issuer, :string, max_size: 16
    field :reason_code, :string, max_size: 32, blank: true, default: ""
    field :reason, :text, blank: true, default: ""
    field :amount, :decimal, max_digits: 20, decimal_places: 4, blank: true, null: true
    field :state, :string, max_size: 16
    field :platform_ref, :string, max_size: 255, blank: true, null: true, unique: true
    field :sent_at, :date_time, blank: true, null: true
    field :error, :text, blank: true, default: ""
    # Opération d'origine (lettrage `matching:<id>`, encaissement
    # `payment:<id>`) : un même lettrage n'émet « Encaissée » qu'une fois.
    field :origin, :string, max_size: 64, blank: true, null: true, unique: true
    field :created_by_id, :big_int, blank: true, null: true
    field :created_at, :date_time

    db_table :einvoicing_lifecycle_event
  end
end
